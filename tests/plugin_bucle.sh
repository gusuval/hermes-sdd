#!/usr/bin/env bash
# El bucle del gateway arranca sin Telegram, uno solo por $HERMES_SDD_HOME, y el vigía de etapas sin latido.
exec python3 "$(dirname "$0")/plugin_bucle.py"
