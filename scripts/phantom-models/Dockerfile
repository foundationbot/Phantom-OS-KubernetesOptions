# phantom-models — FROM scratch image whose only purpose is to be mounted
# as a read-only volume into the positronic-control pod via the
# Kubernetes image: volume source (KEP-4639). Never executed.
#
# The build context is whatever directory contains the models to bundle
# (typically /root/phantom-models-merged on mk09, or a temp dir assembled
# by build.py from a manifest). Everything in the context lands at /models
# inside the image.
#
# Don't add metadata, labels, or layers beyond this — the image is
# content-addressed and any extra layer makes the digest noisier without
# adding value. If a label genuinely belongs on the image (e.g. an OCI
# annotation pointing at the source-of-truth checksum), add it via
# `docker build --label` from build.py rather than here.
FROM scratch
COPY . /models
