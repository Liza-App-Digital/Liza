"""Synapse-модуль media_variants — постановка видео в очередь транскодинга.

При получении m.video event модуль отправляет HTTP POST в media-transcoder
с метаданными видео. Transcoder фоново создаёт варианты качества (720p, 480p)
и публикует state event com.liza.media_variants через Admin API.

Конфигурация (homeserver.yaml):

    modules:
      - module: synapse_modules.media_variants.MediaVariantsModule
        config:
          transcoder_url: http://media-transcoder:8080
          # Минимальный битрейт для транскодинга (bps). Видео ниже — пропускаем.
          min_bitrate_bps: 2500000
          # Минимальная ширина для транскодинга
          min_width: 854
"""

import logging
from typing import Any, Dict

from synapse.config import ConfigError
from synapse.events import EventBase
from synapse.module_api import ModuleApi
from synapse.types import StateMap

from synapse_modules._ha import register_on_new_event_once

logger = logging.getLogger(__name__)


class MediaVariantsModule:
    """Ставит m.video в очередь транскодинга через HTTP к media-transcoder."""

    @staticmethod
    def parse_config(config: Dict[str, Any]) -> Dict[str, Any]:
        transcoder_url = config.get("transcoder_url")
        if not transcoder_url:
            raise ConfigError("media_variants: требуется transcoder_url")
        if not isinstance(transcoder_url, str) or not transcoder_url.startswith("http"):
            raise ConfigError(
                f"media_variants: transcoder_url должен быть http(s)-URL, "
                f"получено: {transcoder_url!r}"
            )
        return {
            "transcoder_url": transcoder_url.rstrip("/"),
            "min_bitrate_bps": int(config.get("min_bitrate_bps", 2_500_000)),
            "min_width": int(config.get("min_width", 854)),
        }

    def __init__(self, config: Dict[str, Any], api: ModuleApi) -> None:
        self._api = api
        self._transcoder_url = config["transcoder_url"]
        self._min_bitrate_bps = config["min_bitrate_bps"]
        self._min_width = config["min_width"]

        # HA: эффект выполняет один процесс инстанса (см. synapse_modules._ha).
        register_on_new_event_once(api, self._on_new_event)

        logger.info(
            "MediaVariantsModule loaded (server=%s, transcoder=%s, "
            "min_bitrate=%d, min_width=%d)",
            api.server_name,
            self._transcoder_url,
            self._min_bitrate_bps,
            self._min_width,
        )

    async def _on_new_event(
        self,
        event: EventBase,
        state_events: StateMap[EventBase],
    ) -> None:
        if event.type != "m.room.message":
            return
        if event.content.get("msgtype") != "m.video":
            return

        mxc = event.content.get("url")
        if not mxc or not isinstance(mxc, str) or not mxc.startswith("mxc://"):
            return

        # E2EE: зашифрованные видео не транскодируем (сервер не видит контент)
        if event.content.get("file"):
            return

        info = event.content.get("info", {})

        # Проверяем media_profile из upload (если ffprobe отработал)
        media_profile = event.content.get("com.liza.media_profile", {})
        should_transcode = media_profile.get("should_transcode", [])

        # Если ffprobe не был — оцениваем по info из event
        if not should_transcode:
            w = info.get("w") or media_profile.get("width", 0)
            h = info.get("h") or media_profile.get("height", 0)
            size = info.get("size", 0)
            duration_ms = info.get("duration", 0)

            if w < self._min_width and h < self._min_width:
                return

            if duration_ms > 0 and size > 0:
                bitrate_bps = size * 8 / (duration_ms / 1000)
                if bitrate_bps < self._min_bitrate_bps:
                    return
            else:
                return

            # Определяем нужные профили
            if w > 1280 or h > 720:
                should_transcode = ["720p", "480p"]
            else:
                should_transcode = ["480p"]

        if not should_transcode:
            return

        # Отправляем задачу в transcoder (не блокируем event processing)
        self._api.run_as_background_process(
            "media_variants_enqueue",
            self._enqueue_transcode,
            event,
            mxc,
            info,
            should_transcode,
        )

    async def _enqueue_transcode(
        self,
        event: EventBase,
        mxc: str,
        info: dict,
        qualities: list,
    ) -> None:
        """HTTP POST к media-transcoder для постановки в очередь."""
        url = f"{self._transcoder_url}/api/v1/transcode"
        body = {
            "room_id": event.room_id,
            "event_id": event.event_id,
            "mxc_url": mxc,
            "server_name": self._api.server_name,
            "info": {
                "w": info.get("w"),
                "h": info.get("h"),
                "size": info.get("size"),
                "duration": info.get("duration"),
                "mimetype": info.get("mimetype"),
            },
            "qualities": qualities,
        }

        http = self._api.http_client
        try:
            response = await http.post_json_get_json(url, body)
            logger.info(
                "media_variants: enqueued %s for %s -> %s (task_id=%s)",
                mxc,
                qualities,
                event.event_id,
                response.get("task_id", "?"),
            )
        except Exception:
            logger.warning(
                "media_variants: failed to enqueue %s for transcoding",
                mxc,
                exc_info=True,
            )
