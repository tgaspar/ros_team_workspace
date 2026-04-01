<!-- RTW-Claude-Config | file: CLAUDE.md | version: 1.0.1 -->
# Development Guidelines

## Agent routing

We have reviewing agents set up.
You must delegate both the plan to the reviewing agents as well as the final written code.
So before working and after working.

### Routing Table

| Trigger | Agent to invoke |
|---|---|
| Working on `.py` files, or `setup.py`, `setup.cfg` | `python-reviewer` agent |
| Working on `.cpp`, `.hpp`, `.h` files | `cpp-reviewer` agent |
| Preparing a pull request | `pull-request-drafter` agent |


### Routing Behavior

- If a task touches multiple file types (e.g., adding a new node requires
  editing `.cpp` + `CMakeLists.txt`), invoke each relevant agent in sequence.
- If unsure which agent applies, ask before proceeding.
- Sub-agent instructions take precedence over general instructions for
  file-type-specific decisions.

## Pre-commits

If a pre-commit files are defined, ensure the pre-commit checks pass.

## Working with ROS 2

When working on ROS 2 project follow these rules:
- Always build with `colcon build --symlink-install` from the worspace directory! If our working directory is `<path>/<to>/<workspace>/src/current_ros_pkg` it means you need to invoke `colcon build ...` from `<path>/<to>/<workspace>`. Same for `source install/setup.bash`.
- Always build with `--symlink-install`
- Follow ROS 2 naming conventions
- Running ROS 2 nodes always happens with `ros2 run <package_name> <executable_name>`
- After building, source the `setup.bash` file from `<workspace>/install/setup.bash`
- In any kind of text (not code), always write `ROS 2`, that is `ROS` + `SPACE` + `2`.
- When asked to write tests, write both unit tests (to test with `colcon test`) as well integration tests `launch_test`
- Run tests with: `colcon test --packages-select <pkg>`
- Always check results with: `colcon test-result --verbose`
- Unit tests live in the `test/` directory of each packag
- Always define `CMakeLists.txt`: `ament_cmake` for C++ and `ament_python` for Python

## Session Memory

At the start of every session:
1. Look for a `.claude-notes.md` file in the current working directory.
   1. If we are in a ROS2 workspace, also look for `.claude-notes.md` in direct sub-directories (one level depth)
2. If it exists, read it fully before doing anything else — it contains
   accumulated knowledge about this project from previous sessions.
3. If it does not exist, create it once you have explored the project
   (after the first non-trivial task).

At the end of a task (or when asked to wrap up):
- Update `.claude-notes.md` with anything learned that would be useful
  next session: package structure, key design decisions, quirks,
  what was recently changed, open TODOs, build gotchas, etc.

### Format of .claude-notes.md

# Project: <name>
Last updated: <date>

## Package Layout
...if in the workspace `src` directory - briefly describe what's in each packages, their purpose...
...if you're in the (ROS2) package directory, write the directory structure and what is usually in them

## Architecture Decisions
...why things are structured the way they are...

## Build / Environment Notes
...distro, any non-standard setup steps, known issues...

## Recent Changes
...what was last worked on, so next session has a running start...
