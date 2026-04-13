# AI Usage Policy

> [!IMPORTANT]
> Element 0 does not accept fully AI-generated pull requests.
> AI tools may be used only for assistance.
> You must understand and take responsibility for every change you submit.
>
> Read and follow [AGENTS.md](./AGENTS.md), [CONTRIBUTING.md](./CONTRIBUTING.md), and [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md).

## Our Rule

All contributions must come from humans who understand and can take full responsibility for their code. LLMs make mistakes and cannot be held
accountable.
Element 0 is a language interpreter and an embedding API, where subtle bugs in the parser, evaluator, FFI, or GC integration can break downstream Zig
projects, so human ownership matters.

> [!WARNING]
> Maintainers may close PRs that appear to be fully or largely AI-generated.

## Getting Help

Before asking an AI, please open or comment on an issue on the [Element 0 issue tracker](https://github.com/Element0Lang/element-0/issues). There are
no silly questions, and language-implementation topics (R5RS semantics, tail calls, continuations, lexical scoping, Boehm GC integration, and Zig FFI
lifetimes) are an area where LLMs often give confident but incorrect answers.

If you do use AI tools, use them for assistance (like a reference or tutor), not generatively (to fully write code for you).

## Guidelines for Using AI Tools

1. Complete understanding of every line of code you submit.
2. Local review and testing before submission, including `make test-all` and `make lint`.
3. Personal responsibility for bugs, regressions, and cross-platform issues in your contribution.
4. Disclosure of which AI tools you used in your PR description.
5. Compliance with all rules in [AGENTS.md](./AGENTS.md) and [CONTRIBUTING.md](./CONTRIBUTING.md).

### Example Disclosure

> I used Claude to help debug a failing `tests/test_edge_cases.elz` case.
> I reviewed the suggested fix, ran `make test-all` locally, and verified it does not regress other tests.

## Allowed (Assistive Use)

- Explanations of existing code in `src/elz/` and `tests/`.
- Suggestions for debugging failing unit, property, integration, or Element 0 language tests.
- Help understand Zig compiler errors or R5RS wording.
- Review of your own code for correctness, clarity, and style.

## Not Allowed (Generative Use)

- Generation of entire PRs or large code blocks, including new primitives in `src/elz/primitives/`, new modules under `src/elz/`, or new test files
  under `tests/`.
- Delegation of implementation or API decisions to the tool, especially for evaluator, parser, FFI, or GC behavior.
- Submission of code you do not understand.
- Generation of documentation, standard library code in `src/stdlib/std.elz`, or comments without your own review.
- Automated or bulk submission of changes produced by agents.

## About AGENTS.md

[AGENTS.md](./AGENTS.md) encodes project rules about architecture, testing, and conventions, and is structured so that LLMs can better comply with
them. Agents may still ignore or be talked out of it; it is a best effort, not a guarantee.
Its presence does not imply endorsement of any specific AI tool or service.

## Licensing Note

Element 0 is licensed under Apache-2.0. It links against dependencies under other licenses (for example, BDWGC, Linenoise, Chilli, and Minish, as
listed in `build.zig.zon`), and contributions must preserve those boundaries. AI-generated code of unclear provenance makes that harder, which is
another reason to keep contributions human-authored.

## AI Disclosure

This policy was adapted, with the assistance of AI tools, from a similar policy used by other open-source projects, and was reviewed and edited by
human contributors to fit Element 0.
