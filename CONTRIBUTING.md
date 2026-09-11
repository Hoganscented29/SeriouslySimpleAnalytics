# Contributing

Bug reports, fixes and ideas are welcome.

## Before you start on something large

Open an issue first. This project is source-available rather than open source
(see [Licensing](#licensing) below), and a change that is large or that moves
the project's direction is better discussed before you spend a weekend on it.

## Developing

```bash
./install.sh --dev
mix run priv/repo/seeds.exs   # demo traffic to look at
```

`mix precommit` must pass before you open a pull request — it compiles with
warnings as errors, checks formatting, and runs the tests.

Tests are the fastest way to get a change accepted. If you are fixing a bug,
a test that fails before your change and passes after it makes the review
trivial.

## Licensing

The project is licensed under the [Functional Source License 1.1][fsl] with an
Apache 2.0 future licence. In short: you can read it, run it, modify it and
build on it for nearly anything — the one thing you cannot do is offer it as a
competing commercial product or service. Each version becomes Apache 2.0 two
years after its release.

**By opening a pull request you agree that your contribution is licensed under
the same terms as the project**, and that the maintainer may license the project
— including your contribution — under different terms in future, such as the
Apache 2.0 future licence the FSL already promises, or a commercial licence.

That second clause is the part worth reading twice. Without it, a single
contribution under different terms would make the promised Apache 2.0 conversion
impossible to honour, because nobody would have the right to relicense that
part. It is not a copyright assignment: you keep ownership of your work.

Please sign off your commits to record that you have the right to submit them,
per the [Developer Certificate of Origin][dco]:

```bash
git commit -s -m "your message"
```

[fsl]: https://fsl.software
[dco]: https://developercertificate.org/
