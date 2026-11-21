---
name: asking-the-user
description: How any la-carte agent asks the user to do something (access, a secret, a click in a UI only they can reach, a decision). Load before writing any request to the user.
---

# Asking the user

The user's time is the scarcest resource. Ask only after a real deep dive (use sub-agents to verify it's
truly impossible), and make their part **the smallest reasonable action**.

## Before asking
- Try it yourself first. "I didn't try" is never a reason.
- Prefer requests that **grant durable autonomy** (an API key wired into an MCP, auto-deploy, an
  endpoint you can check) over one-off manual tasks you'll need again next time.

## Minimize their actions
- Do every step you can; leave them only what truly needs them.
  - Secret: "Copy the key to your clipboard, tell me when done" — then *you* read it with `pbpaste`
    (never print it) and run the commands. Don't hand them a command to paste.
  - UI-only step: the exact click path, nothing else. Then you do the verification.
- One request at a time. No optional extras in the same request.

## Format (short)
1. **What** you'll do.
2. **Why you need them** (the verified blocker, one line).
3. **Their action**: ideally one line. Say what you'll do right after and how you'll confirm it worked.

## Where
Write the request to a file in the scratchpad and open it in nvim in an idle tmux pane below the
manager's pane: find it with `tmux list-panes -a`, then `tmux send-keys -t <session:win.pane> 'nvim <file>' Enter`.
Subagents send the request to the manager, who opens it.

## Example
> **Dokploy access.** I'll add the Dokploy MCP so I can read deploy logs and redeploy myself.
> Needs a key only your Dokploy account can create.
> **You:** Dokploy → Settings → Profile → API/CLI Keys → Generate, copy it, say "done".
> I'll wire it up and confirm by listing la-carte's last deployments.
