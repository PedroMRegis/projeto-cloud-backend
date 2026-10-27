"""Comandos de manutenção, rodados como task avulsa do ECS ou em local.

    python -m app.cli migrate        aplica as migrations pendentes
    python -m app.cli embed          gera embeddings que faltam no catálogo
"""

from __future__ import annotations

import argparse
import json
import sys

from app.shared.logging import configure_logging


def main(argv: list[str] | None = None) -> int:
    configure_logging()
    parser = argparse.ArgumentParser(prog="python -m app.cli")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("migrate", help="aplica as migrations pendentes")
    embed = sub.add_parser("embed", help="gera embeddings que faltam")
    embed.add_argument("--limit", type=int, default=500)
    args = parser.parse_args(argv)

    if args.command == "migrate":
        from app.adapters.db import migrate

        print(json.dumps({"applied": migrate()}))
        return 0

    from app.application.admin import backfill_embeddings

    result = backfill_embeddings(args.limit)
    print(json.dumps(result))
    return 0 if result["pending"] >= 0 else 2


if __name__ == "__main__":
    sys.exit(main())
