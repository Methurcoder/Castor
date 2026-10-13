# AnimeFaceModels

Compiled Core ML models for `AnimeFaceCoreMLEstimator`. They are generated,
not checked in:

    python3 Arils/Tools/AnimeFaceModels/export_coreml.py

This writes `AnimeFaceFeatures`, `AnimeFaceBoxHead` and `AnimeFaceLandmarks`
(`.mlpackage` and compiled `.mlmodelc`) here. Without them Arils works exactly
as before and face review uses its built-in estimator.

Weights: hysts/anime-face-detector (Faster R-CNN R50-FPN, HRNetV2-W18),
MIT License, from the Hugging Face Hub. See THIRD_PARTY_NOTICES.md.
