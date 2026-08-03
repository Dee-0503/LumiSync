# Keyboard Backlight Feasibility Gate

Pass only when all checks are true on an Apple Silicon MacBook:

- Read current built-in keyboard backlight value.
- Set built-in keyboard backlight to 0.0, 0.5, and 1.0.
- Restore the original value after the test.
- Perform the operation through the planned Helper boundary or a documented prototype path.
- Confirm no key contents, display contents, or user files are accessed.

Current status: not verified in this repository.
