"""bench/xlang/python/main.py — pydantic-core's column.

One line out: `<name> <ns/op> <iterations>`. See bench/xlang/README.md.

`model_validate_json` is the fair call: pydantic-core parses and validates in one pass in Rust,
which is the thing Rupa's own JSON decoding deliberately does not do, and the design doc says
why. Building the model classes is import-time work and is not timed, the same way Rupa's
staging is not.
"""

import os
import sys
import time
from typing import Annotated

from pydantic import BaseModel, Field


NonEmpty = Annotated[str, Field(min_length=1)]


class Settings(BaseModel):
    theme: str
    size: int


class Profile(BaseModel):
    age: Annotated[int, Field(ge=0, le=150)]
    city: str
    settings: Settings


class Payload(BaseModel):
    id: NonEmpty
    name: NonEmpty
    active: bool
    score: Annotated[float, Field(ge=0)]
    profile: Profile
    # The per-element constraint lives on the element type, which is the declarative spelling
    # rather than a loop -- the same shape `T.list(T.string(min: 1))` has.
    tags: list[NonEmpty]


def main() -> None:
    path = sys.argv[1]
    with open(path, "rb") as handle:
        data = handle.read()

    # The fixture has to validate before anything is timed, so a fast column can never be one
    # that quietly failed.
    Payload.model_validate_json(data)

    # Both are read from the environment so every column can be re-run at a different warmup
    # with one variable, which is the only way to tell a slow library from an under-warmed one.
    warmup = int(os.environ.get("XLANG_WARMUP", 50_000))
    iterations = int(os.environ.get("XLANG_ITERATIONS", 100_000))

    for _ in range(warmup):
        Payload.model_validate_json(data)

    started = time.perf_counter_ns()
    for _ in range(iterations):
        Payload.model_validate_json(data)
    elapsed = time.perf_counter_ns() - started

    print(f"pydantic-core {elapsed / iterations:.1f} {iterations}")


if __name__ == "__main__":
    main()
