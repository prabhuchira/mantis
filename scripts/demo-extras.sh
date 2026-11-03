#!/bin/sh
# Content for the extras: URLs, file:line, hashes, IPs and log levels.
printf '\033[1mbuild log\033[0m\n'
printf '[12:00:01] INFO  fetching https://ghostty.org/docs/config (mirror 10.0.4.12:8443)\n'
printf '[12:00:02] WARN  deprecated API in Sources/MantisCore/Parser.swift:42:7\n'
printf '[12:00:03] ERROR type mismatch at Terminal.swift:118\n'
printf '[12:00:03] ERROR see ./scripts/build-app.sh for packaging\n'
printf '[12:00:04] INFO  deployed commit 3f9a2c1d to prod — FAILED health check\n'
printf '[12:00:05] INFO  docs: https://en.wikipedia.org/wiki/ANSI_escape_code#CSI_(Control_Sequence_Introducer)_sequences\n'
printf '\n$ git log --oneline -3\n'
printf '\033[33m9e1b7a4\033[0m add hint mode\n\033[33m51c0d2e\033[0m bookmarks + badge\n\033[33ma07f3b9\033[0m initial terminal core\n'
