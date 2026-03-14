# Contributing

Thanks for your interest in contributing to Screen Recorder!

## Getting Started

1. Fork the repository
2. Clone your fork
3. Create a feature branch: `git checkout -b feature/my-feature`
4. Make your changes
5. Build and test: `./build.sh`
6. Commit with a descriptive message
7. Push to your fork and open a Pull Request

## Development Setup

See [DEVELOPMENT.md](DEVELOPMENT.md) for build instructions, requirements, and environment setup.

## Code Style

- Swift conventions (camelCase, etc.)
- Keep files focused — one type/concern per file
- Use `// MARK: -` sections to organize within files
- Document public APIs with `///` doc comments

## Pull Request Guidelines

- **One concern per PR** — don't mix features with refactors
- **Describe what and why** — not just what changed, but why
- **Test your changes** — at minimum, ensure `swift build` passes
- **Screenshots for UI changes** — if you changed the settings UI, control bar, etc.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the source tree and design patterns.

## Reporting Issues

- Use GitHub Issues
- Include macOS version, app version, and steps to reproduce
- For crashes, include the crash log from Console.app
