"""Реальный APNs payload без NSE: имя аудиофайла не является подписью.

ledger:RL-push-media-type-preview
"""

import copy
import json
import unittest
from unittest.mock import Mock

from sygnal.apnspushkin import ApnsPushkin
from sygnal.notifications import Device, Notification


class AudioFallbackTest(unittest.TestCase):
    def payload(self, content, *, group=False, encrypted=False):
        device = Device({"app_id": "ru.prodamus.liza", "pushkey": "test-only"})
        notification = Notification(
            {
                "devices": [],
                "type": "m.room.encrypted" if encrypted else "m.room.message",
                "sender_display_name": "Alice",
                "room_id": "!room:test",
                "event_id": "$event:test",
                "room_name": "Team" if group else None,
                "content": content,
            }
        )
        pushkin = object.__new__(ApnsPushkin)
        return pushkin._get_payload_full(notification, device, Mock(), True)

    # AC:RL-push-media-type-preview/7
    def test_voice_and_audio_without_caption_use_existing_generic_keys(self):
        for voice in (False, True):
            for group in (False, True):
                for reply in (False, True):
                    with self.subTest(voice=voice, group=group, reply=reply):
                        content = {
                            "msgtype": "m.audio",
                            "body": ("> <@bob:test> quoted\n\n" if reply else "")
                            + "recording.ogg",
                            "filename": "recording.ogg",
                        }
                        if voice:
                            content["org.matrix.msc3245.voice"] = {}
                        original = copy.deepcopy(content)
                        result = self.payload(content, group=group)
                        alert = result["aps"]["alert"]
                        self.assertEqual(
                            alert["loc-key"],
                            "MSG_FROM_USER_IN_ROOM" if group else "MSG_FROM_USER",
                        )
                        self.assertEqual(
                            alert["loc-args"], ["Alice", "Team"] if group else ["Alice"]
                        )
                        self.assertNotIn("recording.ogg", json.dumps(result))
                        self.assertEqual(result["content"].get("voice", False), voice)
                        self.assertEqual(content, original)
                        self.assertLess(len(json.dumps(result).encode()), 4096)

    # AC:RL-push-media-type-preview/8
    def test_real_and_legacy_audio_caption_is_preserved_without_reply_quote(self):
        for group in (False, True):
            for legacy in (False, True):
                for voice in (False, True):
                    for reply in (False, True):
                        with self.subTest(
                            group=group, legacy=legacy, voice=voice, reply=reply
                        ):
                            content = {
                                "msgtype": "m.audio",
                                "body": ("> <@bob:test> quoted\n\n" if reply else "")
                                + "Caption",
                            }
                            if voice:
                                content["org.matrix.msc3245.voice"] = {}
                            if not legacy:
                                content["filename"] = "recording.ogg"
                            original = copy.deepcopy(content)
                            result = self.payload(content, group=group)
                            self.assertEqual(
                                result["aps"]["alert"]["loc-key"],
                                (
                                    "MSG_FROM_USER_IN_ROOM_WITH_CONTENT"
                                    if group
                                    else "MSG_FROM_USER_WITH_CONTENT"
                                ),
                            )
                            self.assertEqual(
                                result["aps"]["alert"]["loc-args"][-1], "Caption"
                            )
                            self.assertEqual(result["content"]["body"], "Caption")
                            self.assertEqual(
                                result["content"].get("voice", False), voice
                            )
                            self.assertEqual(content, original)

    # AC:RL-push-media-type-preview/9
    def test_text_image_and_encrypted_controls(self):
        text = self.payload({"msgtype": "m.text", "body": "Hello"})
        self.assertEqual(text["aps"]["alert"]["loc-args"], ["Alice", "Hello"])
        image = self.payload({"msgtype": "m.image", "body": "photo.jpg"})
        self.assertEqual(image["aps"]["alert"]["loc-key"], "IMAGE_FROM_USER")
        encrypted = self.payload(None, encrypted=True)
        self.assertEqual(encrypted["aps"]["alert"]["loc-key"], "MSG_FROM_USER")
        self.assertNotIn("content", encrypted)
