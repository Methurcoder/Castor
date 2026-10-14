# Speech helper license supplements

Upstream LICENSE texts for wheels which do not include their own license file.
The builder uses only a file matching the exact installed distribution version.
Sources:

- tokenizers 0.23.3: https://github.com/huggingface/tokenizers/blob/v0.23.3/LICENSE
- tokenizers 0.22.2: https://github.com/huggingface/tokenizers/blob/v0.22.2/LICENSE
- sentencepiece 0.2.2: https://github.com/google/sentencepiece/blob/v0.2.2/LICENSE

- flatbuffers 25.12.19: https://github.com/google/flatbuffers/blob/v25.12.19/LICENSE
- gradio_client 2.5.0: https://github.com/gradio-app/gradio/blob/gradio_client%402.5.0/LICENSE
- onnxruntime 1.31.0: https://github.com/microsoft/onnxruntime/blob/v1.31.0/LICENSE
- onnxruntime 1.31.0 third-party notices:
  https://github.com/microsoft/onnxruntime/blob/v1.31.0/ThirdPartyNotices.txt

Other versions require their own reviewed license text. Missing license texts
stop the builder before bundling. Exact-version supplemental notices are
included even if a wheel already supplies its main license.
