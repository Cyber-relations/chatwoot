Round 6 fixtures contain synthetic data only.

- `late-marker.docx`, `.xlsx`, `.pptx`: deterministic Office ZIP packages. The first member is `[Content_Types].xml`, with an XML comment before the main-part declaration. The first `word/`, `xl/`, or `ppt/` marker is at byte 8550, beyond Marcel 1.1.0's 4096-byte subtype window. Regenerate from the repository root with `ruby tests/fixtures/generate_chatwoot_office.rb`.
- `recording.wav`: 0.12 seconds of 440 Hz mono PCM at 8000 Hz, generated offline with `ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=8000:duration=0.12' -c:a pcm_s16le -map_metadata -1 -fflags +bitexact -flags:a +bitexact recording.wav`.

The offline content test requires existing Marcel 1.1.0 and Nokogiri; it does not install dependencies or boot Rails:

```sh
ruby -I/path/to/existing/marcel-1.1.0/lib tests/chatwoot_attachment_content_test.rb
```

Its assignment check uses the actual policy, input normalizer and recording writer with an in-memory base writer. ActiveStorage uploads and callback/job persistence are covered by the Rails specs, which must be run separately in the pinned environment.
