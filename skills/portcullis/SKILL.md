---
name: portcullis
description: Keep names, projects and other private terms out of what the model provider sees, by teaching them to the built-in Portcullis PII filter.
version: 1.0.0
author: hermes-suite
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [privacy, pii, redaction, portcullis]
    category: security
---

# Portcullis (PII filter)

This Hermes runs behind Portcullis, a local filter that replaces private values with
placeholders such as `<<EMAIL_1>>` or `<<PERSON_1>>` before a request leaves the machine,
and puts the real values back in the reply. Emails, phone numbers, card numbers, IP
addresses and secrets (API keys, tokens, private keys) are hidden automatically. Names,
companies and projects are hidden only once they are **taught**.

Placeholders you see in the conversation are real values on the user's machine. If you
pass one to a tool (for example in a shell command), it is restored before the tool runs.

## When to use

- The user says something should stay private, confidential or hidden from the AI
  provider: "treat Project Loki as confidential", "don't send my client's name".
- The user asks what is being hidden, or whether something would be sent.
- A chat failed with a message starting "Portcullis blocked this request" or
  "Portcullis (the PII filter …) is not running".

## How

Run these in the terminal:

```bash
portcullis-ctl teach "Project Loki" --label PROJECT    # hide from the next request on
portcullis-ctl teach "Ann" --label PERSON --whole-word  # short names: whole words only
portcullis-ctl test "text to check"                     # what the provider would see
portcullis-ctl terms                                    # what is taught / allowed
portcullis-ctl status                                   # is the filter on and healthy?
```

Pick a short upper-case label that says what the term is: PERSON, ORG, PROJECT, CLIENT,
PRODUCT, LOCATION. Use `--whole-word` for short terms that also appear inside other
words.

Tell the user plainly that the term is hidden **from now on**: the message in which they
named it has already been sent to the provider once.

## Rules

- Only ever *add* protection on your own initiative (`teach`, `test`, `terms`,
  `status`). Run `off`, `unteach`, `allow` or `unallow` only when the user asks for that
  in this conversation, and say what it changes.
- Never print the admin token, `/opt/data/portcullis/env`, `admin_token` or
  `store.json`; the store is a list of everything the user considers private.
- If a request was blocked, relay Portcullis' message and suggest
  `portcullis-ctl status`. Do not try to route around the filter.
