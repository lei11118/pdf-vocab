#!/usr/bin/env python3
"""Convert pinned Hy-MT2 weights to a stateful 4-bit Core ML lab candidate."""

import argparse
from pathlib import Path


MODEL_ID = "tencent/Hy-MT2-1.8B"
REVISION = "9a341cd1b679d3efd23b46e847b01745a71ed792"
CONTEXT_LENGTH = 1536
CHUNK_LENGTH = 128


def convert(output: Path, smoke: bool) -> None:
    import coremltools as ct
    import numpy as np
    import torch
    from transformers import AutoConfig, AutoModelForCausalLM

    class Cache:
        def __init__(self, keys, values, start, end):
            self.keys = keys
            self.values = values
            self.start = start
            self.end = end

        def update(self, key, value, layer):
            self.keys[layer : layer + 1, :, self.start : self.end, :] = key
            self.values[layer : layer + 1, :, self.start : self.end, :] = value
            return self.keys[layer : layer + 1], self.values[layer : layer + 1]

    class Decoder(torch.nn.Module):
        def __init__(self, upstream):
            super().__init__()
            self.backbone = upstream.model
            self.lm_head = upstream.lm_head
            config = upstream.config
            self.state_shape = (config.num_hidden_layers, config.num_key_value_heads,
                                CONTEXT_LENGTH, config.head_dim)
            self.register_buffer("keys", torch.zeros(self.state_shape, dtype=torch.float16))
            self.register_buffer("values", torch.zeros(self.state_shape, dtype=torch.float16))
            self.register_buffer("cached_positions", torch.arange(CONTEXT_LENGTH, dtype=torch.int32))

        def reset(self):
            self.keys.zero_()
            self.values.zero_()

        def forward(self, input_ids, start_position):
            length = input_ids.shape[1]
            start = start_position[0]
            positions = (torch.arange(length, dtype=torch.int32) + start).unsqueeze(0)
            hidden = self.backbone.embed_tokens(input_ids)
            rotary = self.backbone.rotary_emb(hidden, positions)
            visible = self.cached_positions[None, None, None, :] <= positions[:, None, :, None]
            mask = torch.where(visible, 0.0, -65_504.0).to(hidden.dtype)
            cache = Cache(self.keys, self.values, start, start + length)
            for layer in self.backbone.layers:
                hidden = layer(hidden, attention_mask=mask, position_ids=positions,
                               past_key_values=cache, position_embeddings=rotary, use_cache=True)
            last = self.backbone.norm(hidden[:, -1:, :])
            return self.lm_head(last).argmax(dim=-1).to(torch.int32)

    if smoke:
        torch.manual_seed(7)
        config = AutoConfig.from_pretrained(MODEL_ID, revision=REVISION)
        config.hidden_size = 128
        config.num_attention_heads = 4
        config.num_key_value_heads = 2
        config.head_dim = 32
        config.num_hidden_layers = 2
        config.intermediate_size = 256
        config.vocab_size = 256
        config.bos_token_id, config.eos_token_id, config.pad_token_id = 1, 2, 0
        upstream = AutoModelForCausalLM.from_config(config, attn_implementation="eager").half().eval()
    else:
        upstream = AutoModelForCausalLM.from_pretrained(
            MODEL_ID, revision=REVISION, dtype=torch.float16, attn_implementation="eager",
        ).eval()
    decoder = Decoder(upstream).eval()
    seed_ids = [1, 5, 8, 13, 34] if smoke else [120000, 120006, 569, 13, 120007]
    seed = torch.tensor([seed_ids], dtype=torch.int32)
    start = torch.tensor([0], dtype=torch.int32)
    with torch.inference_mode():
        expected = upstream(seed, use_cache=False, logits_to_keep=1).logits.argmax(dim=-1)
        torch.testing.assert_close(decoder(seed, start).long(), expected)
        following = expected.to(torch.int32)
        actual = decoder(following, torch.tensor([seed.shape[1]], dtype=torch.int32)).long()
        reference = upstream(torch.cat((seed, following), dim=1), use_cache=False,
                             logits_to_keep=1).logits.argmax(dim=-1)
        torch.testing.assert_close(actual, reference)
        decoder.reset()
        traced = torch.jit.trace(decoder, (seed, start), check_trace=False)
        decoder.reset()

    sequence = ct.RangeDim(1, CHUNK_LENGTH, default=seed.shape[1])
    model = ct.convert(
        traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS18,
        inputs=[ct.TensorType(name="input_ids", shape=(1, sequence), dtype=np.int32),
                ct.TensorType(name="start_position", shape=(1,), dtype=np.int32)],
        outputs=[ct.TensorType(name="next_token", dtype=np.int32)],
        states=[ct.StateType(name=name,
                             wrapped_type=ct.TensorType(shape=decoder.state_shape, dtype=np.float16))
                for name in ("keys", "values")],
        skip_model_load=True,
    )
    config = ct.optimize.coreml.OptimizationConfig(
        global_config=ct.optimize.coreml.OpLinearQuantizerConfig(
            mode="linear_symmetric", dtype="int4", granularity="per_block", block_size=32,
        ),
    )
    candidate = ct.optimize.coreml.linear_quantize_weights(model, config)
    candidate.author = "Tencent Hy-MT2, converted for PdfVocab"
    candidate.license = "Apache-2.0"
    candidate.user_defined_metadata["pdfvocab.weights_revision"] = "synthetic-smoke" if smoke else REVISION
    candidate.save(str(output))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="Destination with an .mlpackage suffix")
    parser.add_argument("--smoke", action="store_true", help="Use a tiny random checkpoint to test conversion")
    args = parser.parse_args()
    if args.output.suffix != ".mlpackage" or args.output.exists():
        parser.error("output must be a new .mlpackage path")
    convert(args.output, args.smoke)
