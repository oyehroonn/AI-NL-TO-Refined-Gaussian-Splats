"""AR-guided capture pipeline (iPhone ARKit → capture package → splat).

Mirrors upload_to_splat/ in shape, but the early stages are replaced by an
ARKit-driven capture instead of an uploaded video. Layer 0 = session +
QR + capture intake. Higher AR-layers (iOS app, pose bridge, LiDAR adapter)
land in their own subpackages.
"""
