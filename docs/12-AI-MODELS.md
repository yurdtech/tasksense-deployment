# AI features on an internal model

Optional, and off unless you configure them. Everything else in TaskSense works
without them.

**No data leaves your network.** You point the product at a model endpoint you
host; nothing is sent to us or to any model vendor. Prompts contain task text
(titles, descriptions, comments that are not internal); they do not contain
credentials or attachments.

---

## What they do

| Feature | What happens |
| --- | --- |
| Summarise a document | One request to the model, one answer |
| Break a task into subtasks | Same |
| Triage incoming work | Same |
| Agents working a task | The dispatcher hands a task to an agent, the model drafts the plan, description, acceptance criteria or checklist — **as a draft in a review lane** that a person with `approve_agent_work` accepts |

All of it is "knowledge mode": a request and a structured answer, **no tools**.
The model never runs a command, never touches the file system, and never calls
anything but the endpoint you configured.

> **Tool-using execution is not available.** Earlier documentation described
> an "agent executor" running model-authored commands in a sandboxed workspace.
> No sandbox ships with TaskSense, so the executor stays off:
> `AGENT_EXECUTOR=off` is the only supported value, the application refuses
> anything else at startup, `preflight.sh` fails on it, and neither the wizard
> nor the Helm chart sets it.

---

## Connecting a model

Any OpenAI-compatible `/v1/chat/completions` endpoint works — vLLM, Ollama,
LM Studio, LiteLLM, or a gateway you already run.

### 1. Let the server reach it

Outbound requests to private addresses are refused by default, and your model
server is on one. Allow it by name, and trust its certificate if your CA issued
it:

```dotenv
EGRESS_ALLOWLIST=llm-gateway.bank.internal
NODE_EXTRA_CA_CERTS=/certs/bank-ca.pem     # if the gateway's certificate is from your CA
AGENT_DISPATCHER=on                        # the scheduler that advances agent work
AGENT_EXECUTOR=off                         # always
```

```bash
docker compose -f compose/docker-compose.yml up -d
```

Open the firewall from the TaskSense host to the gateway as well
([18-PRE-INSTALL-CHECKLIST](18-PRE-INSTALL-CHECKLIST.md#2-firewall-matrix), O6).

### 2. Add the provider

In **Agents → Settings & roles** (administrators):

1. Add a provider, kind `openai-compatible`.
2. Base URL: `https://llm-gateway.bank.internal/v1`
3. API key: whatever your endpoint expects, or a placeholder if it expects
   none. It is encrypted at rest with `STORAGE_SECRET` and never returned by
   the API.
4. Model: the name your endpoint serves.
5. **Test**, then make it active.

Expected: the test answers with the model's reply within a few seconds.

Do **not** set `ANTHROPIC_API_KEY` in `.env` for a bank installation: it is a
server-wide fallback for a cloud provider. Connect your gateway as above, where
the key is encrypted.

---

## Running a model

### vLLM, with a GPU

```bash
docker run -d --name vllm --gpus all -p 8000:8000 \
  -v /models:/models \
  vllm/vllm-openai:<pinned version> \
  --model /models/Qwen2.5-14B-Instruct --served-model-name tasksense
```

| Model size | GPU memory | Good for |
| --- | --- | --- |
| 7–8B | 16 GB | Summaries, decomposition |
| 14B | 32 GB | The above, noticeably better; triage |
| 32B+ | 80 GB | The best drafts for agent work |

### Ollama, without one

```bash
docker run -d --name ollama -p 11434:11434 -v ollama:/root/.ollama ollama/ollama
docker exec ollama ollama pull qwen2.5:7b
```

Base URL: `http://ollama.bank.internal:11434/v1`

CPU inference is slow — tens of seconds per summary. Fine for evaluating
whether the features are worth a GPU; frustrating as a daily tool.

### Air-gapped

Download the model weights where you have internet, carry them in, and point
`--model` at the local path. Neither vLLM nor Ollama needs the internet once the
weights are present. Mirror their images like the TaskSense image.

---

## Without a model

Nothing breaks. The AI surfaces stay available and fall back to deterministic
behaviour — summaries become extracts, decomposition becomes a template. It is
plainly less useful, and honest about being so.

To switch the AI features off completely: `AGENT_DISPATCHER=off`, and
disconnect the provider in Agents → Settings & roles.

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| "Test" fails with a blocked-URL error | The host is not in `EGRESS_ALLOWLIST` | Add it, `up -d` |
| "Test" fails with `unable to get local issuer certificate` | The gateway's certificate is from your CA | `NODE_EXTRA_CA_CERTS=/certs/bank-ca.pem` |
| Test passes, agents do nothing | `AGENT_DISPATCHER=off` | `AGENT_DISPATCHER=on`, `up -d` |
| Very slow | CPU inference, or a model too large for the GPU | A GPU, or a smaller model |
| Malformed-response errors | The model is too small to hold a JSON format | 7B or larger |
| The application logs that the executor was refused | `AGENT_EXECUTOR` is not `off` | Set `AGENT_EXECUTOR=off` |

```bash
docker compose -f compose/docker-compose.yml logs app | grep -iE 'agent|llm|provider'
```
