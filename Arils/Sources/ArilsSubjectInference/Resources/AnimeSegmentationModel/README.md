# AnimeSegmentationModel

Compiled Core ML model for the anime character segmentation used by
`VisionSubjectMaskProvider`. It is generated, not checked in:

    python3 Arils/Tools/AnimeSegmentationModel/export_coreml.py

This writes `AnimeSegmentation.mlmodelc` here (and the editable `.mlpackage`
under `Tools/AnimeSegmentationModel/build/`). Without it Arils works as
before: Vision's mask refined against the image colors.

Weights: skytnt/anime-seg (ISNet), Apache License 2.0, from the Hugging Face
Hub; network definition from SkyTNT/anime-segmentation, Apache License 2.0.
See THIRD_PARTY_NOTICES.md.
