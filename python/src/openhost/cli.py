"""`openhost` CLI."""
from __future__ import annotations

import signal
import time
from typing import Optional

import typer

from . import download as _download
from .presets import get_preset, list_presets
from .registry import get_registry


app = typer.Typer(
    help="OpenHost — run local LLMs with a Langchain-compatible API.",
    no_args_is_help=True,
)


@app.command("list")
def list_cmd() -> None:
    """Show available model presets."""
    for p in list_presets():
        present = _download.is_present(p)
        mark = "✓" if present else " "
        typer.echo(f"{mark} {p.id:36s}  {p.backend:10s}  {p.display_name}")
    typer.echo("\n(✓ = already downloaded to ~/.openhost/models/)")


@app.command("pull")
def pull_cmd(model_id: str) -> None:
    """Download a model to ~/.openhost/models/."""
    preset = get_preset(model_id)
    if preset is None:
        typer.echo(f"Unknown preset: {model_id}", err=True)
        raise typer.Exit(code=1)
    typer.echo(f"Pulling {preset.display_name} from {preset.hf_repo}…")
    path = _download.pull(preset)
    typer.echo(f"Done → {path}")


@app.command("run")
def run_cmd(
    model_id: str,
    port: Optional[int] = typer.Option(None, help="Bind to a specific port."),
    keep_alive: bool = typer.Option(True, help="Keep the server running in foreground."),
) -> None:
    """Start a model server and (optionally) block until Ctrl-C."""
    preset = get_preset(model_id)
    if preset is None:
        typer.echo(f"Unknown preset: {model_id}", err=True)
        raise typer.Exit(code=1)

    from .runner import ModelRunner

    runner = ModelRunner(preset, port=port)
    try:
        info = runner.start()
    except Exception as exc:
        typer.echo(f"✗ {exc}", err=True)
        raise typer.Exit(code=1)

    typer.echo(f"✓ {preset.id} running on {info.base_url}  (upstream id: {info.upstream_model_id})")
    if not keep_alive:
        return

    typer.echo("Press Ctrl-C to stop.")
    try:
        signal.signal(signal.SIGINT, _sigint_handler)
        while runner.is_running:
            time.sleep(0.5)
    finally:
        runner.stop()
        typer.echo("Stopped.")


def _sigint_handler(signum, frame):
    raise KeyboardInterrupt


@app.command("stop")
def stop_cmd(model_id: str) -> None:
    """Stop a model running in this process (only useful within a single Python session)."""
    get_registry().stop(model_id)
    typer.echo(f"Stopped {model_id}.")


@app.command("doctor")
def doctor_cmd() -> None:
    """Diagnose install: hardware, llama.cpp backend, GPU readiness."""
    from . import check_setup
    check_setup()


@app.command("running")
def running_cmd() -> None:
    """Show runners alive in the current process (most useful from `python -m openhost`)."""
    registry = get_registry()
    rows = registry.running()
    if not rows:
        typer.echo("(none)")
        return
    for r in rows:
        info = r.info()
        typer.echo(f"{info.id}\tpid={info.pid}\t{info.base_url}")


def main() -> None:
    app()


if __name__ == "__main__":
    main()
