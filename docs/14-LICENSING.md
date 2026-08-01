# Licensing

What a licence key is, what it changes, and what happens when it lapses.

The short version: it is one line in your configuration, it is checked on your
own hardware, and **nothing about it can stop you reaching your data**.

---

## Without a licence

The instance runs. Two limits apply:

| | Free | Licensed |
| --- | --- | --- |
| People with accounts | **10** | as many as the licence says, or unlimited |
| Automation rule runs | **500 per calendar month** | unlimited |

Everything else is the same software: boards, sprints, the docs knowledge base,
reporting, LDAP and OIDC sign-in, backups, the API, the audit log. There is no
feature behind the licence — only those two numbers.

## Getting one

Email **info@meiksense.io** with the organisation the licence is for and how
many people will have accounts. You will receive a single line:

```
LICENSE_KEY=tsl_eyJvcmciOiJBQkIgQmFuayIsInBsYW4iOiJwcm8i…
```

Put it in `compose/.env` (or `licenseKey` in your Helm values) and restart. The
guided installer asks for it during setup.

That is the whole process. There is no account to create, no portal to sign in
to, and nothing to install.

## How it is checked

The key is two parts: a payload and an Ed25519 signature. The payload is your
organisation's name, a seat count and an optional expiry date. The signature is
made with a private key that never leaves us, and verified against a public key
compiled into the image you are already running.

**Verification is local.** No activation server, no phone-home, no usage
reporting, no update check. An air-gapped installation validates its licence the
same way one with internet access does, because neither one uses the network for
it. `docs/06-SECURITY.md` describes how to confirm that rather than take our word
for it.

The payload is signed, not encrypted — you can read it:

```bash
grep LICENSE_KEY compose/.env | cut -d_ -f2- | cut -d. -f1 | base64 -d
{"org":"ABB Bank","plan":"pro","seats":200,"exp":"2027-08-01"}
```

You should be able to see what you were sold. What nobody can do is change a
number in it: altering the payload breaks the signature, and the instance falls
back to free-tier limits.

## When it expires

Nothing is locked, nothing is deleted, and nobody is signed out.

The two limits above come back. Your data, your history, your attachments and
your integrations are untouched and fully accessible — an expired licence is a
billing state, not a kill switch.

Renewals are a new key for the same `.env` line. Email
**info@meiksense.io** before the date on the key.

## Going over the seat count

On-premise, **nothing is blocked**. If your organisation grows past the number on
the licence, people keep signing in and working; the overage is reported so that
we can settle it in a renewal rather than at somebody's sign-in prompt.

You can see it three ways:

```bash
curl -s -H "Authorization: Bearer <token>" \
  http://localhost:3000/api/v1/team/seats
{"used":213,"limit":200,"plan":"pro","over":13}
```

- **Admin → Plan & billing** shows seats used against the licence
- **`tasksense_seats_over_limit`** in the Prometheus metrics — `0` while within
  it. `docs/09-MONITORING.md` has an alert for it
- The **application log** repeats the licence line daily

## Checking the state

```bash
curl -s -H "Authorization: Bearer <token>" \
  http://localhost:3000/api/v1/billing/status | jq .licence
```

| `state` | What it means | What to do |
| --- | --- | --- |
| `absent` | No `LICENSE_KEY` set | Free-tier limits apply. Nothing is wrong |
| `valid` | Verified | `expiresInDays` counts down; `null` means perpetual |
| `expired` | Verified, but the date has passed | Renew. Free-tier limits are in force |
| `invalid` | Present, signature does not verify | Usually a key copied short. It must start with `tsl_` and include everything after it |

The same four states appear in the log at startup and once a day after that, and
in Admin → Plan & billing.

## Questions we get asked

**Does the licence tie the software to one machine?**
No. There is no hardware binding and no instance count. Restoring a backup onto
new hardware, standing up a test environment, or moving to a new host needs
nothing from us.

**Does anything about our usage reach you?**
No. Nothing in a running installation contacts us, licence included — see
`docs/06-SECURITY.md`, which is written for a security review.

**Can a licence be revoked remotely?**
No, and this follows from the above: an instance that never calls us cannot be
told anything. A licence is good until the date inside it.

**Is the registry token the same thing?**
No. The token controls *downloading the image*; the licence controls the two
limits. They are independent — see `docs/13-REGISTRY-ACCESS.md`.
