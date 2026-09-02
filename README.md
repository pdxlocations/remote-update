# Meshtastic serial update checker

Run `meshtastic-update-check.sh` on the Luckfox Lyra over SSH. It reads the connected node's firmware through the Meshtastic CLI and lists the five most recent GitHub releases labelled Alpha or Beta. You may choose any listed release, including an older version.

Install the CLI once (along with `curl` and `python3`):

```sh
python3 -m pip install --user 'meshtastic[cli]'
```

Then copy the script to the Luckfox and run:

```sh
chmod +x meshtastic-update-check.sh
./meshtastic-update-check.sh --port /dev/ttyUSB0
```

If exactly one `/dev/ttyUSB*` or `/dev/ttyACM*` device exists, `--port` is optional. The script only downloads release metadata before the prompt; it downloads firmware only after you select a numbered release. Use `--dry-run` to list releases without downloading or flashing. The normal CLI update mode is used (not a wipe), but keep a configuration backup and ensure stable power while flashing.
