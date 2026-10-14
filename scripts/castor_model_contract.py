"""Release-only required Core ML model contract; no download or fallback."""
FACE_MODELS = ("AnimeFaceFeatures", "AnimeFaceBoxHead", "AnimeFaceLandmarks")
REQUIRED_FILES = ("coremldata.bin", "model.mil", "weights/weight.bin")

def require_model(directory):
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Required compiled model is missing: " + directory.name)
    for name in REQUIRED_FILES:
        file = directory / name
        if file.is_symlink() or not file.is_file() or file.stat().st_size == 0:
            raise ValueError("Required compiled model is incomplete: " + directory.name + "/" + name)

def required_source_models(root):
    face = root / "Arils/Sources/ArilsFaceInference/Resources/AnimeFaceModels"
    segmentation = root / "Arils/Sources/ArilsSubjectInference/Resources/AnimeSegmentationModel"
    return [*(face/(name+".mlmodelc") for name in FACE_MODELS), segmentation/"AnimeSegmentation.mlmodelc"]

def required_app_models(app):
    resources = app / "Contents/Resources"
    face = resources / "Arils_ArilsFaceInference.bundle/Contents/Resources/AnimeFaceModels"
    segmentation = resources / "Arils_ArilsSubjectInference.bundle/Contents/Resources/AnimeSegmentationModel"
    return [*(face/(name+".mlmodelc") for name in FACE_MODELS), segmentation/"AnimeSegmentation.mlmodelc"]

def require_source_models(root):
    for model in required_source_models(root): require_model(model)

def require_app_models(app):
    for model in required_app_models(app): require_model(model)
