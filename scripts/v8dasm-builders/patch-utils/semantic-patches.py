#!/usr/bin/env python3
"""Semantic View8/v8dasm patches for V8 (including 12.4.x / Node 22)."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path


NL = "\n"  # real newline in generated C++ source
# C++ string containing backslash-n (escape sequence text)
CPP_N = "\\" + "n"


class SemanticPatcher:
    def __init__(self, v8_dir: str, log_file: str):
        self.v8_dir = Path(v8_dir)
        self.log_file = Path(log_file)
        self.ok = 0
        self.fail = 0

    def log(self, msg: str) -> None:
        print(msg)
        with self.log_file.open("a", encoding="utf-8") as f:
            f.write(msg + NL)

    def _read(self, rel: str):
        path = self.v8_dir / rel
        if not path.exists():
            self.log(f"[SEMANTIC] missing: {rel}")
            return None, None
        return path, path.read_text(encoding="utf-8", errors="surrogateescape")

    def _write(self, path: Path, content: str) -> None:
        path.write_text(content, encoding="utf-8", newline="\n")

    def patch_sanity_check(self) -> bool:
        """Bypass SanityCheck + dump SharedFunctionInfo after Deserialize."""
        rel = "src/snapshot/code-serializer.cc"
        path, content = self._read(rel)
        if path is None:
            return False

        already = ("Start SharedFunctionInfo" in content) and (
            "return SerializedCodeSanityCheckResult::kSuccess;" in content
        )
        if already and "GetBytecodeArray" not in content:
            # sanity already bypassed and dump present
            pass

        # Replace SanityCheck body (1-arg or 2-arg).
        pattern = re.compile(
            r"(SerializedCodeSanityCheckResult\s+SerializedCodeData::SanityCheck\s*"
            r"\([^;]*?\)\s*const\s*\{)(.*?)(\n\})",
            re.DOTALL,
        )
        if not pattern.search(content):
            self.log("[SEMANTIC] SanityCheck function not found")
            return False

        def repl_sanity(m: re.Match) -> str:
            return m.group(1) + NL + "  return SerializedCodeSanityCheckResult::kSuccess;" + m.group(3)

        content = pattern.sub(repl_sanity, content, count=1)

        if "Start SharedFunctionInfo" not in content:
            dump_lines = [
                f'  std::cout << "{CPP_N}Start SharedFunctionInfo{CPP_N}";',
                "  result->SharedFunctionInfoPrint(std::cout);",
                f'  std::cout << "{CPP_N}End SharedFunctionInfo{CPP_N}";',
                "  std::cout << std::flush;",
                "",
            ]
            dump = NL.join(dump_lines) + NL

            needle = "  Tagged<Script> script = Script::cast(result->script());"
            if needle not in content:
                self.log("[SEMANTIC] could not find Deserialize insert point")
                return False
            content = content.replace(needle, dump + needle, 1)

        if "#include <iostream>" not in content:
            content = content.replace(
                '#include "src/snapshot/code-serializer.h"',
                '#include "src/snapshot/code-serializer.h"' + NL + "#include <iostream>",
                1,
            )

        self._write(path, content)
        self.log("[SEMANTIC] patched code-serializer.cc")
        return True

    def patch_objects_printer(self) -> bool:
        """Dump bytecode inside SharedFunctionInfoPrint."""
        rel = "src/diagnostics/objects-printer.cc"
        path, content = self._read(rel)
        if path is None:
            return False

        if "Start BytecodeArray" in content:
            self.log("[SEMANTIC] objects-printer.cc already patched")
            return True

        old = "  PrintSourceCode(os);"
        idx = content.find("void SharedFunctionInfo::SharedFunctionInfoPrint")
        if idx < 0:
            self.log("[SEMANTIC] SharedFunctionInfoPrint not found")
            return False
        pos = content.find(old, idx)
        if pos < 0:
            self.log("[SEMANTIC] PrintSourceCode inside SharedFunctionInfoPrint not found")
            return False

        replacement = NL.join(
            [
                "  // View8/v8dasm: emit bytecode instead of source.",
                "  if (HasBytecodeArray()) {",
                "    Isolate* isolate_for_bc = nullptr;",
                "    if (GetIsolateFromHeapObject(*this, &isolate_for_bc)) {",
                f'      os << "{CPP_N}Start BytecodeArray{CPP_N}";',
                "      GetBytecodeArray(isolate_for_bc)->Disassemble(os);",
                f'      os << "{CPP_N}End BytecodeArray{CPP_N}";',
                "      os << std::flush;",
                "    }",
                "  } else {",
                "    PrintSourceCode(os);",
                "  }",
            ]
        )
        content = content[:pos] + replacement + content[pos + len(old) :]
        self._write(path, content)
        self.log("[SEMANTIC] patched objects-printer.cc")
        return True

    def patch_string_cc(self) -> bool:
        rel = "src/objects/string.cc"
        path, content = self._read(rel)
        if path is None:
            return False

        pattern = re.compile(
            r"\s*if\s*\(\s*len\s*>\s*kMaxShortPrintLength\s*\)\s*\{.*?\}\s*\n",
            re.DOTALL,
        )
        if not pattern.search(content):
            self.log("[SEMANTIC] string.cc truncate block missing (ok)")
            return True
        content = pattern.sub(NL, content, count=1)
        self._write(path, content)
        self.log("[SEMANTIC] patched string.cc")
        return True

    def patch_deserializer(self) -> bool:
        rel = "src/snapshot/deserializer.cc"
        path, content = self._read(rel)
        if path is None:
            return False

        pattern = re.compile(
            r"\s*CHECK_EQ\s*\(\s*magic_number_\s*,\s*SerializedData::kMagicNumber\s*\)\s*;\s*\n?"
        )
        if not pattern.search(content):
            self.log("[SEMANTIC] deserializer magic check missing (ok)")
            return True
        content = pattern.sub(NL, content, count=1)
        self._write(path, content)
        self.log("[SEMANTIC] patched deserializer.cc")
        return True

    def apply_all(self) -> bool:
        self.log("[SEMANTIC] start")
        steps = [
            ("code-serializer.cc", self.patch_sanity_check),
            ("objects-printer.cc", self.patch_objects_printer),
            ("string.cc", self.patch_string_cc),
            ("deserializer.cc", self.patch_deserializer),
        ]
        for name, fn in steps:
            self.log(f"[SEMANTIC] {name}")
            try:
                if fn():
                    self.ok += 1
                else:
                    self.fail += 1
            except Exception as exc:  # noqa: BLE001
                self.log(f"[SEMANTIC] exception in {name}: {exc}")
                self.fail += 1

        self.log(f"[SEMANTIC] done ok={self.ok} fail={self.fail}")
        return self.ok >= 2 and self.fail == 0


def main() -> int:
    if len(sys.argv) < 3:
        print("Usage: semantic-patches.py <v8_dir> <log_file>")
        return 1
    v8_dir, log_file = sys.argv[1], sys.argv[2]
    if not os.path.isdir(v8_dir):
        print(f"ERROR: missing v8 dir: {v8_dir}")
        return 1
    return 0 if SemanticPatcher(v8_dir, log_file).apply_all() else 1


if __name__ == "__main__":
    raise SystemExit(main())
