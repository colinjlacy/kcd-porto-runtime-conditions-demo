"""Applies a RuntimeConditionsProfile to the management cluster on behalf of the build pipeline.

Event: {"profile": <RuntimeConditionsProfile as JSON>, "imageDigest": "sha256:<64 hex>" (optional)}

The profile is applied with server-side apply under a fixed field manager, so the same profile
name always updates the same resource (its UID is kept) and never overwrites other profiles.
"""

import base64
import json
import os
import re
import ssl
import urllib.error
import urllib.request

import boto3
from botocore.signers import RequestSigner

API_GROUP = "runtimeconditions.io"
API_VERSION = "v1alpha1"
KIND = "RuntimeConditionsProfile"
PLURAL = "runtimeconditionsprofiles"
FIELD_MANAGER = "profile-publisher"
IMAGE_ANNOTATION = "demo.runtimeconditions.io/image"

DIGEST_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")
NAME_PATTERN = re.compile(r"^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$")
REQUEST_TIMEOUT_SECONDS = 20


class InvalidRequest(Exception):
    """The event cannot be turned into a profile to apply."""


def build_manifest(event, namespace):
    if not isinstance(event, dict) or not isinstance(event.get("profile"), dict):
        raise InvalidRequest("event.profile must be a JSON object")
    profile = event["profile"]
    if profile.get("apiVersion") != f"{API_GROUP}/{API_VERSION}" or profile.get("kind") != KIND:
        raise InvalidRequest(f"profile must be a {API_GROUP}/{API_VERSION} {KIND}")

    metadata = profile.get("metadata")
    name = metadata.get("name") if isinstance(metadata, dict) else None
    if not isinstance(name, str) or not NAME_PATTERN.match(name):
        raise InvalidRequest("profile.metadata.name must be a valid Kubernetes resource name")

    annotations = dict(metadata.get("annotations") or {})
    digest = event.get("imageDigest")
    if digest is not None:
        if not isinstance(digest, str) or not DIGEST_PATTERN.match(digest):
            raise InvalidRequest("imageDigest must look like sha256:<64 lowercase hex characters>")
        annotations[IMAGE_ANNOTATION] = digest
    else:
        annotations.pop(IMAGE_ANNOTATION, None)

    manifest_metadata = {"name": name, "namespace": namespace}
    if annotations:
        manifest_metadata["annotations"] = annotations
    if metadata.get("labels"):
        manifest_metadata["labels"] = metadata["labels"]
    # Server-managed metadata and status are never taken from the caller.
    return {key: value for key, value in profile.items() if key not in ("metadata", "status")} | {
        "metadata": manifest_metadata
    }


def eks_token(cluster_name, region):
    """A short-lived bearer token for the EKS API, signed with the function's own role."""
    session = boto3.session.Session()
    sts = session.client("sts", region_name=region)
    signer = RequestSigner(sts.meta.service_model.service_id, region, "sts", "v4", session.get_credentials(), session.events)
    url = signer.generate_presigned_url(
        {
            "method": "GET",
            "url": f"https://sts.{region}.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15",
            "body": {},
            "headers": {"x-k8s-aws-id": cluster_name},
            "context": {},
        },
        region_name=region,
        expires_in=60,
        operation_name="",
    )
    return "k8s-aws-v1." + base64.urlsafe_b64encode(url.encode()).decode().rstrip("=")


def apply_manifest(manifest, endpoint, ca_pem, token):
    namespace = manifest["metadata"]["namespace"]
    name = manifest["metadata"]["name"]
    url = (
        f"{endpoint}/apis/{API_GROUP}/{API_VERSION}/namespaces/{namespace}/{PLURAL}/{name}"
        f"?fieldManager={FIELD_MANAGER}&force=true"
    )
    request = urllib.request.Request(
        url,
        data=json.dumps(manifest).encode(),
        method="PATCH",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/apply-patch+yaml",
            "Accept": "application/json",
        },
    )
    context = ssl.create_default_context(cadata=ca_pem) if endpoint.startswith("https://") else None
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS, context=context) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise RuntimeError(f"Kubernetes API rejected the profile ({error.code}): {detail}") from None


def handler(event, _context, token_provider=eks_token):
    endpoint = os.environ["CLUSTER_ENDPOINT"].rstrip("/")
    cluster_name = os.environ["CLUSTER_NAME"]
    namespace = os.environ["PROFILE_NAMESPACE"]
    ca_pem = base64.b64decode(os.environ["CLUSTER_CA_DATA"]).decode()

    manifest = build_manifest(event, namespace)
    token = token_provider(cluster_name, os.environ["AWS_REGION"])
    applied = apply_manifest(manifest, endpoint, ca_pem, token)

    metadata = applied["metadata"]
    result = {
        "name": metadata["name"],
        "namespace": metadata["namespace"],
        "uid": metadata["uid"],
        "generation": metadata.get("generation"),
        "image": metadata.get("annotations", {}).get(IMAGE_ANNOTATION),
    }
    print(json.dumps({"applied": result}))
    return result
