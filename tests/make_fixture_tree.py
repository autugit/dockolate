#!/usr/bin/env python3
"""造一棵假的「权重目录树」，给 tests/verify_identity.sh 用。

用法：make_fixture_tree.py <目标目录>
产出：
  mlx-4bit/config.json + model-00001-of-00001.safetensors   （MLX 4bit 目录）
  gguf-model/main-Q4_K_M.gguf                               （带 GGUF 头的主权重）
  gguf-model/mtp-draft-Q8_0.gguf                            （草稿头）
  gguf-dup/                                                 （与 gguf-model 的权重同 inode：硬链接副本）
  empty/config.json                                         （只有 config、没有权重）
  vae/diffusion_pytorch_model.safetensors                   （VAE 角色）
"""
import json
import os
import struct
import sys

root = sys.argv[1]
os.makedirs(root, exist_ok=True)


def gguf(path, arch, name, tensors=1, payload=4096):
    """写一个只有头部 + 填充的假 GGUF（够身份识别用）"""
    kvs = [(b"general.architecture", arch.encode()), (b"general.name", name.encode())]
    with open(path, "wb") as f:
        f.write(b"GGUF")
        f.write(struct.pack("<I", 3))          # version
        f.write(struct.pack("<Q", tensors))    # tensor count
        f.write(struct.pack("<Q", len(kvs)))   # kv count
        for k, v in kvs:
            f.write(struct.pack("<Q", len(k)))
            f.write(k)
            f.write(struct.pack("<I", 8))      # 类型：string
            f.write(struct.pack("<Q", len(v)))
            f.write(v)
        f.write(b"\0" * payload)              # 假张量区


def safetensors(path, metadata=None, payload=2048):
    header = {"__metadata__": metadata or {"format": "mlx"}, "w": {"dtype": "BF16", "shape": [8], "data_offsets": [0, 16]}}
    raw = json.dumps(header).encode()
    with open(path, "wb") as f:
        f.write(struct.pack("<Q", len(raw)))
        f.write(raw)
        f.write(b"\0" * payload)


# 1) MLX 目录
d = os.path.join(root, "mlx-4bit")
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "config.json"), "w") as f:
    json.dump({"architectures": ["TestForCausalLM"], "model_type": "test",
               "quantization": {"bits": 4, "group_size": 64, "mode": "affine"}}, f)
safetensors(os.path.join(d, "model-00001-of-00001.safetensors"))

# 2) GGUF 目录（主权重）
d = os.path.join(root, "gguf-model")
os.makedirs(d, exist_ok=True)
gguf(os.path.join(d, "main-Q4_K_M.gguf"), "test-arch", "Test Model 7B")

# 2b) 草稿头单独一个目录（真实布局：draft 与主权重分开放）
d = os.path.join(root, "gguf-draft")
os.makedirs(d, exist_ok=True)
gguf(os.path.join(d, "mtp-draft-Q8_0.gguf"), "test-arch-mtp", "Test Model 7B")

# 3) 硬链接副本：目录换了名字，字节是同一 inode ⇒ 清单里必须只出现一次
d2 = os.path.join(root, "gguf-dup")
os.makedirs(d2, exist_ok=True)
for src in ("main-Q4_K_M.gguf",):
    os.link(os.path.join(root, "gguf-model", src), os.path.join(d2, src))

# 4) 空壳：只有 config，没有权重
d = os.path.join(root, "empty")
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "config.json"), "w") as f:
    json.dump({"architectures": ["TestEmpty"]}, f)

# 5) VAE 角色
d = os.path.join(root, "vae")
os.makedirs(d, exist_ok=True)
safetensors(os.path.join(d, "diffusion_pytorch_model.safetensors"))

print("fixture tree:", root)
