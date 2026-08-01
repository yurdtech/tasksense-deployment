# AI features on an internal model

Optional, and off unless you configure them. Everything else in TaskSense works
without them.

**No data leaves your network.** You point the product at a model endpoint you
host; nothing is sent to us or to any model vendor.

---

## What they do

| | Needs |
| --- | --- |
| Summarise a document | A model endpoint |
| Break a task into subtasks | A model endpoint |
| Triage incoming work | A model endpoint |
| Agents that carry out tasks | A model endpoint **and** `AGENT_EXECUTOR=on` |

The first three are ordinary request-and-response. The last one runs
model-authored commands in a sandboxed workspace — read [what that
means](#the-agent-executor) before enabling it.

---

## Connecting a model

Any OpenAI-compatible `/v1/chat/completions` endpoint works, which in practice
means vLLM, Ollama, LM Studio, or a gateway you already run.

In **Admin → Agents → Providers**:

1. Add a provider, kind `openai-compatible` (or `local`).
2. Base URL: `http://vllm.bank.internal:8000/v1`
3. API key: whatever your endpoint expects, or a placeholder if it expects none.
   It is encrypted at rest with `STORAGE_SECRET`.
4. Model: the name your endpoint serves.
5. **Test**, then **Make active**.

Then, in `.env`:

```bash
AGENT_DISPATCHER=on          # the scheduler that advances agent work
EGRESS_ALLOWLIST=vllm.bank.internal
```

`EGRESS_ALLOWLIST` matters: outbound requests to private addresses are refused by
default, and your model server is on a private address. This is the setting that
makes reaching it a deliberate decision rather than an accident.

---

## Running a model

### vLLM, with a GPU

```bash
docker run -d --name vllm --gpus all -p 8000:8000 \
  -v /models:/models \
  vllm/vllm-openai:latest \
  --model /models/Qwen2.5-14B-Instruct --served-model-name tasksense
```

| Model size | GPU memory | Good for |
| --- | --- | --- |
| 7–8B | 16 GB | Summaries, decomposition |
| 14B | 32 GB | The above, noticeably better |
| 32B+ | 80 GB | Agent execution |

### Ollama, without one

```bash
docker run -d --name ollama -p 11434:11434 -v ollama:/root/.ollama ollama/ollama
docker exec ollama ollama pull qwen2.5:7b
```

Base URL: `http://ollama.bank.internal:11434/v1`

CPU inference is slow — tens of seconds per summary. Fine for evaluating whether
the features are worth a GPU; frustrating as a daily tool.

### Air-gapped

Download the model weights where you have internet, carry them in, and point
`--model` at the local path. Neither vLLM nor Ollama needs the internet once the
weights are present.

---

## The agent executor

`AGENT_EXECUTOR=on` lets an agent run commands the model wrote, in a workspace
directory under the data volume.

**Off by default, and it should stay off unless you have decided otherwise.**
A model that can run commands is a model that can run the wrong command. The
workspace is isolated, but the process reaches the container's network and its
filesystem within that directory.

Enable it only if you want agents to do work rather than propose it, and only
after reviewing what a run can touch. The other AI features do not need it.

---

## Without a model

Nothing breaks. The AI surfaces stay available and fall back to deterministic
behaviour — summaries become extracts, decomposition becomes a template. It is
plainly less useful, and it is honest about being so.

---

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| "Test" fails with a blocked-URL error | Add the host to `EGRESS_ALLOWLIST` |
| Test passes, features do nothing | `AGENT_DISPATCHER=off` |
| Very slow | CPU inference, or a model too large for the GPU |
| Malformed-response errors | The model is too small to hold a JSON format. Use 7B or larger. |

```bash
docker compose -f compose/docker-compose.yml logs app | grep -iE 'agent|llm|provider'
```
