import srsly
import random
import os
import itertools
from abc import ABC
import math
from typing import Callable, Dict, List
from collections import defaultdict

import torch
from tqdm import tqdm
from datasets import Dataset
import ray
import torch
from dataclasses import dataclass
from ray.util.placement_group import placement_group

from ttrl.trainer.ppo_actor import ActorModelRayActor
from ttrl.trainer.ppo_critic import CriticModelRayActor
from ttrl.models.vllm_engine import create_vllm_engines
from ttrl.models.ray_launcher import PPORayActorGroup, ReferenceModelRayActor, RewardModelRayActor
from ttrl.datasets.prompts_dataset import PromptDatasetWithLabel
from ttrl.datasets.sft_dataset import SFTDataset
from ttrl.helper.utils import blending_datasets, get_tokenizer
from ttrl.helper.distributed_sampler import DistributedSampler, ResumableRandomSampler

from ttrl.env.naive_samples_maker import NaiveSamplesMaker
from ttrl.env.ttt_samples_maker import TTTSamplesMaker
from ttrl.controller.naive_controller import NaiveController

@dataclass
class Agent:
    # One agent includes actor model (many workers), critic model, reference model, and vllm engines for PPO training
    # The agent can start training after making trajectory samples by itself or with other agents
    actor_model_group: PPORayActorGroup
    critic_model_group: PPORayActorGroup
    vllm_engines: List

    def save_actor_and_critic_model(self, args, tokenizer):
        ray.get(self.actor_model_group.async_save_model())
        if args.critic_pretrain and args.save_value_network:
            ray.get(self.critic_model_group.async_save_model())

        # save tokenizer
        tokenizer.save_pretrained(args.save_path)

@ray.remote
def generate_samples_remote(samples_maker, chunk_prompts, rank, world_size, generate_kwargs):
    samples_list, all_prompts, all_pred_outputs, all_pred_labels, ttt_metrics = samples_maker.generate_samples(chunk_prompts, rank, world_size, **generate_kwargs)
    return {
        "sample": samples_list,
        "prompt": all_prompts,
        "output": all_pred_outputs,
        "label": all_pred_labels,
        "ttt_metrics": ttt_metrics
    }

class TTTController(NaiveController):
    def generate_shared_samples(self, rand_prompts):
        world_size = self.agent.actor_model_group.world_size

        if len(rand_prompts) < world_size:
            samples_ref = generate_samples_remote.remote(self.samples_maker, rand_prompts, 0, 1, self.generate_kwargs)
            old_all_results = ray.get(samples_ref)

            all_samples = old_all_results["sample"]
            if len(all_samples) % world_size != 0:
                raise ValueError(f"{len(all_samples)} can not be divied by {world_size}!")

            size = len(all_samples) // world_size
            all_samples = [all_samples[i*size:(i+1)*size] for i in range(world_size)]
            assert len(all_samples) == world_size, f"{len(all_samples)} != {world_size}"

            all_results = [{"sample": samples, "ttt_metrics": old_all_results["ttt_metrics"]} for samples in all_samples]
        else:
            any_key = next(iter(rand_prompts.keys()))
            length = len(rand_prompts[any_key])
            chunk_size = (length + world_size - 1) // world_size
            chunked = [dict() for _ in range(world_size)]
            for key, data_list in rand_prompts.items():
                for i in range(world_size):
                    start_idx = i * chunk_size
                    end_idx = min(start_idx + chunk_size, length)
                    sub_slice = data_list[start_idx:end_idx]
                    chunked[i][key] = sub_slice

            all_refs = []
            for rank in range(world_size):
                samples_ref = generate_samples_remote.remote(self.samples_maker, chunked[rank], rank, world_size, self.generate_kwargs)
                all_refs.append(samples_ref)
            all_results = ray.get(all_refs)

        shared_data_refs = [None for _ in range(world_size)]
        sft_samples = []

        # Ensure all workers have the same number of samples, avoid stucking
        # Especially when we filter samples by rewards
        if self.args.filter_samples_by_reward:
            min_num_samples = min([len(x) for x in all_results])
            num_full_batches = (min_num_samples * self.args.micro_rollout_batch_size) // self.args.train_batch_size
            num_elements_to_keep = (num_full_batches * self.args.train_batch_size) // self.args.micro_rollout_batch_size

        # create samples for each actor worker
        for rank in range(world_size):

            shared_data = all_results[rank]["sample"]
            if self.args.filter_samples_by_reward:
                shared_data = shared_data[:num_elements_to_keep]

            shared_ref = ray.put(shared_data)
            if self.args.training_mode in ["sft", "both", "mix"]:
                sft_samples.extend(self.build_sft_sample_list(shared_data))

            shared_data_refs[rank] = shared_ref

        # Collect all ttt_metrics on all nodes
        ttt_metrics = []
        for rank in range(world_size):
            ttt_metrics.append(all_results[rank]["ttt_metrics"])
        # print(f"ttt_metrics: {ttt_metrics}")
        # [{'hit_rate': 0.625, 'majority_ratio': 0.650390625, 'true_label_ratio': 0.439453125}, {'hit_rate': 0.578125, 'majority_ratio': 0.58203125, 'true_label_ratio': 0.416015625}]
        ttt_metrics_avg = {}
        if ttt_metrics:
            keys = ttt_metrics[0].keys()
            for key in keys:
                total = 0
                for metric in ttt_metrics:
                    total += metric[key]
                ttt_metrics_avg[key] = total / len(ttt_metrics)
        ttt_metrics = ttt_metrics_avg

        print(f"ttt_metrics: {ttt_metrics}")

        if len(sft_samples) > 0:
            for sample in random.sample(sft_samples, 3):
                print(sample)
                print("="*20)
            return shared_data_refs, ray.put(self.build_sft_dataset(sft_samples)), ttt_metrics
        else:
            return shared_data_refs, None, ttt_metrics

    def fit(self,
            consumed_samples=0,
            num_update_steps_per_episodes=1,
        ) -> None:
        args = self.args

        num_rollouts_per_episodes = (
            num_update_steps_per_episodes
            * args.train_batch_size
            // args.max_epochs
            // args.rollout_batch_size
            // args.n_samples_per_prompt
        )

        # Restore step and start_epoch
        steps = consumed_samples // args.rollout_batch_size + 1
        start_episode = consumed_samples // args.rollout_batch_size // num_rollouts_per_episodes
        consumed_samples = consumed_samples % (
            num_rollouts_per_episodes * args.rollout_batch_size)

        # Eval before training
        acc = self.evaluate_samples(0)
        self.save_logs(args, 0, {"eval/acc": acc}, None)
        if args.extra_eval_task:
            acc_extra_tasks = self.evaluate_extra_tasks()
            for task, acc in acc_extra_tasks.items():
                self.save_logs(args, 0, {f"eval/acc_{task}": acc}, None)

        for episode in range(start_episode, args.num_episodes):
            if isinstance(self.prompts_dataloader.sampler, ResumableRandomSampler):
                self.prompts_dataloader.sampler.set_epoch(
                    episode, consumed_samples=0 if episode > start_episode else consumed_samples
                )
            pbar = tqdm(
                range(self.prompts_dataloader.__len__()),
                desc=f"Episode [{episode + 1}/{args.num_episodes}]"
            )

            # pass generated samples to each actor worker
            for rand_prompts in self.prompts_dataloader:

                # make shared samples refs
                shared_data_refs, sft_dataset, ttt_metrics = self.generate_shared_samples(
                    rand_prompts=rand_prompts)

                # start training actor models (workers)
                refs = self.agent.actor_model_group.async_fit_actor_model(
                    steps, shared_data_refs, sft_dataset)
                results = ray.get(refs)

                # find result from rank 0
                for result in results:
                    logs_dict, is_rank_0, perf_stats = result["status"], result["is_rank_0"], result["perf_stats"]
                    if is_rank_0:
                        break

                # load ttt metrics
                keys = ttt_metrics.keys()
                for key in keys:
                    logs_dict[key] = ttt_metrics[key]

                if steps % args.eval_steps == 0:
                    acc = self.evaluate_samples(steps)
                    logs_dict["eval/acc"] = acc
                    if args.extra_eval_task:
                        acc_extra_tasks = self.evaluate_extra_tasks()
                        for task, acc in acc_extra_tasks.items():
                            logs_dict[f"eval/acc_{task}"] = acc

                self.save_logs(args, steps, logs_dict, perf_stats)

                pbar.set_postfix(logs_dict)
                pbar.update()
                steps = steps + 1

        if self._wandb is not None:
            self._wandb.finish()
        if self._tensorboard is not None:
            self._tensorboard.close()
