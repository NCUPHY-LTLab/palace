## Code Review Rules

- Review against the Issue named on the PR's `Issue:` line; a PR with no
  readable Issue has unverified acceptance.
- Review in two stages. First look for counterexamples from the change's
  normal entry points, including combinations that break assumptions (two
  valid inputs paired wrongly, two calls writing one output target, a result
  that passes quality but exceeds a limit the caller set). Then weigh each
  against the Issue, the public docs and the callers you can see.
- Each finding states the condition that reproduces it, what the code does,
  the code or assumption that causes it, and a proposed disposition with its
  basis: `fix` (a supported use breaks a promised behavior), `document` (the
  formal flow guarantees a precondition nothing states) or `observe` (no
  known caller reaches it). "Callers outside this repository not checked" is
  a valid basis.
- Flag as P1: a supported use breaking an acceptance criterion, a public
  contract, data or security, or Human-confirmed UI; an out-of-scope input
  that silently produces a plausible but wrong result; a test double
  standing in for the result being claimed (a real solver, database,
  authorization or integration). A counterexample outside the supported use
  is not P1 by itself.
- Test doubles that isolate dependencies are fine; call counts are fine when
  the count is the contract. Do not ask for checks the Issue does not need.
- A CI change must say in the PR what runs when, before and after, the
  expected time change and what could break.
