#!/usr/bin/env python3
"""Execute all three runner Bash blocks against the real launcher and stub Codex."""

from __future__ import annotations

import importlib.util
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from types import ModuleType
from typing import Callable, cast

ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "agents" / "runner.md"
LAUNCHER = Path(os.environ.get("CODEX_DELEGATE_TEST_BIN", ROOT / "bin" / "codex-delegate"))
GUARD = ROOT / "hooks" / "guard-bash.py"
STUB = ROOT / "tests" / "stub"
BLOCK = re.compile(r"^```bash\n(.*?)^```$", re.DOTALL | re.MULTILINE)
PLACEHOLDER = re.compile(r"<[A-Z_]+>")
PID_RECORD = re.compile(rb"CODEX_DELEGATE_LAUNCHER_PID=([1-9][0-9]*)\n\Z")
RUNID_RECORD = re.compile(rb"CODEX_DELEGATE_RUNID=(runner-[0-9a-f]{32})\n\Z")
END_RECORD = re.compile(rb"CODEX_DELEGATE_LAUNCHER_ENDED=([1-9][0-9]*)\n\Z")
DELIMITER = "CODEX_DELEGATE_PROMPT_" + "0123456789abcdef" * 2


def blocks() -> tuple[str, str, str]:
    found = cast("list[str]", BLOCK.findall(RUNNER.read_text(encoding="utf-8")))
    if len(found) != 3:
        raise ValueError(f"runner.md has {len(found)} Bash blocks, expected three")
    return found[0], found[1], found[2]


def fill(block: str, label: str, values: dict[str, str]) -> str:
    used: set[str] = set()

    def replace(match: re.Match[str]) -> str:
        name = match.group(0)
        if name not in values:
            raise ValueError(f"{label} block uses unsupported placeholder {name}")
        used.add(name)
        return values[name]

    result = PLACEHOLDER.sub(replace, block)
    unused = sorted(set(values) - used)
    if unused:
        raise ValueError(f"{label} fixture does not exercise placeholders {unused}")
    return result


def bash(script: str, env: dict[str, str], timeout: float = 10) -> subprocess.CompletedProcess[str]:
    return subprocess.run(  # noqa: S603 -- Executes a checked-in runner prescription.
        ["/bin/bash", "-c", script],
        capture_output=True,
        text=True,
        env=env,
        timeout=timeout,
        check=False,
    )


def launch(script: str, output_path: Path, env: dict[str, str]) -> int:
    with output_path.open("wb") as output:
        completed = subprocess.run(  # noqa: S603 -- Executes the checked-in launcher block.
            ["/bin/bash", "-c", script],
            stdout=output,
            stderr=subprocess.STDOUT,
            env=env,
            timeout=30,
            check=False,
        )
    return completed.returncode


def start(script: str, output_path: Path, env: dict[str, str]) -> subprocess.Popen[bytes]:
    output = output_path.open("wb")
    process = subprocess.Popen(  # noqa: S603 -- Executes the checked-in launcher block.
        ["/bin/bash", "-c", script], stdout=output, stderr=subprocess.STDOUT, env=env
    )
    output.close()
    return process


def records(path: Path) -> tuple[int | None, str | None, bool]:
    pid: int | None = None
    runid: str | None = None
    ended = False
    try:
        lines = path.read_bytes().splitlines(keepends=True)
    except OSError:
        return pid, runid, ended
    for line in lines:
        pid_match = PID_RECORD.fullmatch(line)
        runid_match = RUNID_RECORD.fullmatch(line)
        end_match = END_RECORD.fullmatch(line)
        if pid is None and pid_match is not None:
            pid = int(pid_match.group(1))
        elif pid is not None and runid is None and runid_match is not None:
            runid = runid_match.group(1).decode("ascii")
        elif pid is not None and end_match is not None and int(end_match.group(1)) == pid:
            ended = True
    return pid, runid, ended


def without_records(path: Path) -> bytes:
    lines = path.read_bytes().splitlines(keepends=True)
    pid: bytes | None = None
    pid_index: int | None = None
    runid_index: int | None = None
    end_indices: list[int] = []
    for index, line in enumerate(lines):
        pid_match = PID_RECORD.fullmatch(line)
        runid_match = RUNID_RECORD.fullmatch(line)
        end_match = END_RECORD.fullmatch(line)
        if pid is None and pid_match is not None:
            pid = pid_match.group(1)
            pid_index = index
        elif pid is not None and runid_index is None and runid_match is not None:
            runid_index = index
        elif pid is not None and end_match is not None and end_match.group(1) == pid:
            end_indices.append(index)
    skipped = {item for item in (pid_index, runid_index) if item is not None}
    if end_indices:
        skipped.add(end_indices[-1])
    return b"".join(line for index, line in enumerate(lines) if index not in skipped)


def wait_for_records(path: Path, need_runid: bool, timeout: float = 10) -> tuple[int, str | None]:
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        pid, runid, _ = records(path)
        if pid is not None and (runid is not None or not need_runid):
            return pid, runid
        time.sleep(0.02)
    raise RuntimeError(f"timed out waiting for launcher records in {path}")


def guard() -> ModuleType:
    spec = importlib.util.spec_from_file_location("guard_bash", GUARD)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {GUARD}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def terminate_group(path: Path) -> None:
    try:
        os.killpg(int(path.read_text(encoding="ascii").strip()), signal.SIGKILL)
    except (OSError, ValueError):
        pass


def startup_probe_launcher(work: Path) -> Path:
    source = LAUNCHER.read_text(encoding="utf-8")
    pattern = re.compile(r"^RUNNER_STARTUP_SECONDS = [0-9]+$", re.MULTILINE)
    if len(pattern.findall(source)) != 1:
        raise RuntimeError("launcher does not define one literal RUNNER_STARTUP_SECONDS")
    probe = work / "startup-probe-launcher"
    probe.write_text(pattern.sub("RUNNER_STARTUP_SECONDS = 1", source), encoding="utf-8")
    probe.chmod(0o755)
    return probe


def check_protocol(launcher: str, wait: str, report: str, work: Path) -> list[str]:
    problems: list[str] = []
    bin_dir = work / "bin"
    home = work / "home"
    run_root = work / "runs"
    bin_dir.mkdir()
    home.mkdir()
    run_root.mkdir()
    (bin_dir / "codex-delegate").symlink_to(LAUNCHER)
    env = {
        "PATH": f"{bin_dir}:{STUB}:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(home),
        "CODEX_DELEGATE_HOME": str(run_root),
        "STUB_MODE": "ok",
    }
    launcher_script = fill(
        launcher,
        "launcher",
        {
            "<ARGS>": "--sandbox read-only --deadline 60",
            "<PROMPT>": "a prompt body",
            "<DELIMITER>": DELIMITER,
        },
    )

    refusal_prompt = work / "refusal-prompt.txt"
    refusal_prompt.write_text("runner refusal probe\n", encoding="utf-8")
    refusal = subprocess.run(  # noqa: S603 -- Executes the selected launcher under test.
        [
            str(LAUNCHER),
            "run",
            "--prompt-file",
            str(refusal_prompt),
            "--sandbox",
            "read-only",
            "--deadline",
            "60",
            "--runner-handoff",
            "--runid",
            "runner-refusal-probe",
        ],
        capture_output=True,
        text=True,
        env=env,
        timeout=10,
        check=False,
    )
    if refusal.returncode != 2 or "--runner-handoff cannot be combined with --runid" not in refusal.stderr:
        problems.append("launcher accepted --runner-handoff combined with --runid")

    (run_root / "runner-a1b2c3d4e5f6a7b8").mkdir()
    success_output = work / "success.out"
    if launch(launcher_script, success_output, env) != 0:
        return [f"launcher block failed: {success_output.read_text(errors='replace')}"]
    pid, runid, ended = records(success_output)
    if pid is None or runid is None or not ended:
        return [f"launcher block did not publish complete records: {(pid, runid, ended)!r}"]
    if runid == "runner-a1b2c3d4e5f6a7b8" or not (run_root / runid / "pid").is_file():
        problems.append("launcher did not mint a collision-safe ID with a PID artifact")
    wait_script = fill(wait, "wait", {"<OUTPUT_FILE>": str(success_output)})
    wait_result = bash(wait_script, env)
    if wait_result.returncode != 0 or wait_result.stdout.strip() != "ENDED":
        problems.append("completed runner-wait did not return ENDED")
    report_script = fill(report, "report", {"<OUTPUT_FILE>": str(success_output)})
    report_result = bash(report_script, env)
    if report_result.returncode != 0 or report_result.stdout.encode() != without_records(success_output):
        problems.append("runner-report did not preserve completed launcher output byte for byte")

    no_end_output = work / "complete-without-end.out"
    success_lines = success_output.read_bytes().splitlines(keepends=True)
    no_end_output.write_bytes(b"".join(line for line in success_lines if not END_RECORD.fullmatch(line)))
    no_end_report = bash(fill(report, "report", {"<OUTPUT_FILE>": str(no_end_output)}), env)
    if no_end_report.returncode != 0 or no_end_report.stdout.encode() != without_records(no_end_output) or "no result" in no_end_report.stdout:
        problems.append("a complete result without the end record became a contradictory no-result report")

    missing_runid = "runner-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    missing_no_end_output = work / "missing-without-end.out"
    missing_no_end_output.write_text(f"CODEX_DELEGATE_LAUNCHER_PID=1\nCODEX_DELEGATE_RUNID={missing_runid}\ntruncated launcher output\n")
    missing_no_end_report = bash(fill(report, "report", {"<OUTPUT_FILE>": str(missing_no_end_output)}), env)
    if (
        missing_no_end_report.returncode != 0
        or "truncated launcher output" not in missing_no_end_report.stdout
        or "preceding output may be incomplete" not in missing_no_end_report.stdout
    ):
        problems.append("a missing run directory hid an absent launcher end record")

    second_output = work / "second.out"
    if launch(launcher_script, second_output, env) != 0 or records(second_output)[1] == runid:
        problems.append("two runner launches did not receive distinct launcher-minted IDs")

    failure_output = work / "failure.out"
    failure_script = fill(
        launcher,
        "launcher",
        {
            "<ARGS>": "--sandbox read-only --deadline 60 --not-a-runner-flag",
            "<PROMPT>": "a prompt body",
            "<DELIMITER>": DELIMITER,
        },
    )
    failure_rc = launch(failure_script, failure_output, env)
    failure_wait = bash(fill(wait, "wait", {"<OUTPUT_FILE>": str(failure_output)}), env)
    failure_report = bash(fill(report, "report", {"<OUTPUT_FILE>": str(failure_output)}), env)
    if failure_rc != 2 or failure_wait.stdout.strip() != "ENDED":
        problems.append("pre-allocation launcher failure did not terminate its wait")
    if (
        failure_report.returncode != 0
        or failure_report.stdout.encode() != without_records(failure_output)
        or "unrecognized arguments" not in failure_report.stdout
    ):
        problems.append("runner-report did not preserve a pre-allocation launcher diagnostic")

    live_output = work / "live.out"
    stub_pid = work / "live-stub.pid"
    descendant_pid = work / "live-descendant.pid"
    live_env = {
        **env,
        "STUB_MODE": "hold",
        "STUB_PID_CAPTURE": str(stub_pid),
        "STUB_DESCENDANT_CAPTURE": str(descendant_pid),
    }
    live = start(launcher_script, live_output, live_env)
    waiter: subprocess.Popen[str] | None = None
    try:
        live_pid, live_runid = wait_for_records(live_output, True)
        if live_runid is None:
            raise RuntimeError("live launcher has no run ID")
        with live_output.open("ab") as output:
            output.write(f"CODEX_DELEGATE_LAUNCHER_ENDED={live_pid}\n".encode("ascii"))
        if not records(live_output)[2]:
            problems.append("protocol fixture could not append its premature end marker")
        premature_report = bash(fill(report, "report", {"<OUTPUT_FILE>": str(live_output)}), env)
        if premature_report.returncode != 2 or "still running" not in premature_report.stderr:
            problems.append("runner-report trusted an output marker over the live PID lock")
        live_wait = fill(wait, "wait", {"<OUTPUT_FILE>": str(live_output)})
        waiter = subprocess.Popen(  # noqa: S603 -- Executes the checked-in wait block.
            ["/bin/bash", "-c", live_wait],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        time.sleep(2)
        if waiter.poll() is not None:
            problems.append("runner-wait trusted an output marker while the launcher still held its PID lock")
        os.kill(live_pid, signal.SIGKILL)
        live.wait(timeout=10)
        waiter_stdout, waiter_stderr = waiter.communicate(timeout=10)
        if waiter.returncode != 0 or waiter_stdout.strip() != "ENDED":
            problems.append(f"runner-wait did not survive SIGKILL: {waiter_stdout!r} {waiter_stderr!r}")
        killed_report = bash(fill(report, "report", {"<OUTPUT_FILE>": str(live_output)}), env)
        if killed_report.returncode != 0 or "launcher ended before it could report" not in killed_report.stdout:
            problems.append("runner-report did not diagnose a killed launcher with no result")
    finally:
        if waiter is not None and waiter.poll() is None:
            waiter.kill()
            waiter.wait()
        if live.poll() is None:
            live.kill()
            live.wait()
        terminate_group(stub_pid)
        terminate_group(descendant_pid)

    absent_output = work / "absent.out"
    empty_output = work / "empty.out"
    pid_only_output = work / "pid-only.out"
    unreadable_output = work / "unreadable.out"
    empty_output.touch()
    unreadable_output.write_text("not readable\n", encoding="ascii")
    unreadable_output.chmod(0)
    exited = subprocess.Popen(["/usr/bin/true"])  # noqa: S603
    dead_pid = exited.pid
    exited.wait()
    pid_only_output.write_text(f"CODEX_DELEGATE_LAUNCHER_PID={dead_pid}\n", encoding="ascii")
    pid_only_script = fill(wait, "wait", {"<OUTPUT_FILE>": str(pid_only_output)})
    try:
        pid_only_result = bash(pid_only_script, env, 6)
    except subprocess.TimeoutExpired:
        problems.append("pid-only output for a dead launcher did not terminate within 6 seconds")
    else:
        if pid_only_result.returncode != 0 or pid_only_result.stdout.strip() != "ENDED":
            problems.append("pid-only output for a dead launcher did not return ENDED")

    unresolved: list[tuple[str, subprocess.Popen[str]]] = []
    try:
        for label, path in (
            ("absent", absent_output),
            ("empty", empty_output),
        ):
            unresolved.append(
                (
                    label,
                    subprocess.Popen(  # noqa: S603 -- Executes the checked-in wait block.
                        ["/bin/bash", "-c", fill(wait, "wait", {"<OUTPUT_FILE>": str(path)})],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        env=env,
                    ),
                )
            )
        time.sleep(6)
        for label, process in unresolved:
            if process.poll() is not None:
                stdout, stderr = process.communicate()
                problems.append(f"{label} runner output ended before its startup grace: {stdout!r} {stderr!r}")
    finally:
        for _, process in unresolved:
            if process.poll() is None:
                process.kill()
                process.wait()

    startup_probe = startup_probe_launcher(work)
    for label, path in (("absent", absent_output), ("empty", empty_output)):
        result = subprocess.run(  # noqa: S603 -- Executes a bounded copy of the real launcher.
            [str(startup_probe), "runner-wait", str(path)],
            capture_output=True,
            text=True,
            env=env,
            timeout=4,
            check=False,
        )
        if result.returncode != 0 or result.stdout.strip() != "ENDED":
            problems.append(f"{label} runner output did not end after its bounded startup grace")

    for label, path in (
        ("absent", absent_output),
        ("empty", empty_output),
        ("unreadable", unreadable_output),
    ):
        result = bash(fill(report, "report", {"<OUTPUT_FILE>": str(path)}), env)
        lines = result.stdout.splitlines()
        if result.returncode != 0 or len(lines) != 1 or not lines[0].startswith("codex-delegate:") or "Traceback" in result.stderr:
            problems.append(f"{label} report input does not return one no-result diagnostic")
    unreadable_output.chmod(0o600)

    no_command_output = work / "no-command.out"
    no_command_output.write_text("bash: codex-delegate: command not found\n", encoding="ascii")
    no_command_report = bash(fill(report, "report", {"<OUTPUT_FILE>": str(no_command_output)}), env)
    if no_command_report.returncode != 0 or "command not found" not in no_command_report.stdout or "codex-delegate:" not in no_command_report.stdout:
        problems.append("a failed kickoff did not preserve its diagnostic and add launcher context")
    return problems


def main() -> int:
    problems: list[str] = []
    try:
        launcher, wait, report = blocks()
        if wait.strip() != 'codex-delegate runner-wait "<OUTPUT_FILE>"':
            problems.append("runner wait is not the one-line runner-wait command")
        if report.strip() != 'codex-delegate runner-report "<OUTPUT_FILE>"':
            problems.append("runner report is not the one-line runner-report command")
        if "--runner-handoff" not in launcher or "--runid" in launcher:
            problems.append("launcher block does not delegate run-ID generation to the launcher")
        starts_codex = cast(Callable[[str], bool], guard().starts_codex)
        for label, script in (("launcher", launcher), ("wait", wait), ("report", report)):
            values = {
                "launcher": {
                    "<ARGS>": "--sandbox read-only --deadline 60",
                    "<PROMPT>": "a prompt body",
                    "<DELIMITER>": DELIMITER,
                },
                "wait": {"<OUTPUT_FILE>": str(ROOT / "runner-protocol-output")},
                "report": {"<OUTPUT_FILE>": str(ROOT / "runner-protocol-output")},
            }[label]
            filled = fill(script, label, values)
            parsed = subprocess.run(  # noqa: S603 -- Syntax check of a checked-in Bash block.
                ["/bin/bash", "-n"], input=filled, text=True, capture_output=True, check=False
            )
            if parsed.returncode != 0:
                problems.append(f"{label} block is not valid Bash")
            if starts_codex(filled):
                problems.append(f"the Bash guard denies the {label} block")
        if not problems:
            with tempfile.TemporaryDirectory() as raw:
                base = Path(raw).resolve()
                physical = base / "physical"
                physical.mkdir()
                alias = base / "symlinked-temp"
                alias.symlink_to(physical, target_is_directory=True)
                work = alias / "protocol"
                work.mkdir()
                problems.extend(check_protocol(launcher, wait, report, work.resolve()))
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        problems.append(str(error))

    for problem in problems:
        print(f"runner-protocol: FAIL: {problem}")
    if problems:
        return 1
    print(
        "runner-protocol: PASS: all 3 blocks execute; minted-ID, collision, success, "
        "handoff/runid refusal, startup-failure, pre-RUNID-death, lock-authority, SIGKILL, symlinked-temp, "
        "absent-output, missing-end-record, no-result, and verbatim-report paths pass"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
