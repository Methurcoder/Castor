# Arils corpus

The repository's manually reviewed `Arils_Dataset` can be run as a small,
reproducible pilot baseline from either the repository root or `Arils/`:

```sh
swift run --package-path Arils arils-corpus --pilot
# or, from Arils/: swift run arils-corpus --pilot
```

This pilot is useful for detecting regressions, but it is not evidence of
production accuracy: it contains only the current local illustration set and
does not replace a held-out external corpus.

Corpus images are intentionally external. Copy `manifest.example.json`, replace
the image paths and manually confirmed face rectangles, then run:

```sh
swift run arils-corpus /absolute/path/to/manifest.json > baseline.csv
```

`boundaryPrecision` is the fraction of predicted face-rectangle boundary
samples within 1.5% of the image diagonal (minimum 2 px) of the confirmed
boundary. `faceConfidence`, `reviewConfidence`, and `reviewIssues` preserve the
evidence that made an individual proposal eligible (or ineligible) for automatic
use, so a false approval can be traced back to estimator confidence versus the
independent geometry checks. `autoApprovalRate` and `falseApprovalRate` are
emitted on the summary row; a false approval is an automatically accepted
proposal below the manifest's minimum boundary precision.
`falseApprovalRateUpper95` is the one-sided value taken from the two-sided 95%
Wilson interval, which makes the uncertainty of a small accepted sample visible.
The integrity columns contain the worst pose in the build-time sweep.

`validationDisposition` separates hard safety from soft quality:

- `rejected`: inversion, non-finite geometry, unsupported-pixel exposure, or
  an invalid metric exceeded its hard threshold.
- `requiresReview`: hard safety passed, but rest-pose hole/ghost comparison
  exceeded the visual-quality threshold.
- `accepted`: both groups passed. `autoBuildEligible` additionally requires
  the face proposal to have passed automatic review.

The regular pose-limit columns retain the legacy combined safe+quality range.
The `safety*` columns show the larger range that passes hard safety alone.

When the manifest or corpus is absent the command exits successfully with a
single `skipped` summary row, so local and CI builds do not require private
images.
