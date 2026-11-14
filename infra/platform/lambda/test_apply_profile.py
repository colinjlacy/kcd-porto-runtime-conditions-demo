import base64
import json
import os
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest import mock
from urllib.parse import parse_qs, urlparse

import apply_profile

DIGEST = "sha256:" + "ab" * 32
PROFILE = {
    "apiVersion": "runtimeconditions.io/v1alpha1",
    "kind": "RuntimeConditionsProfile",
    "metadata": {"name": "shipment-notifier"},
    "workload": {"uri": "https://github.com/example/demo", "version": "abc123"},
    "conditions": [{"kind": "datastore"}],
}


class FakeKubernetesApi:
    """Records requests and answers like the API server does for server-side apply."""

    def __init__(self, status=200):
        self.requests = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_PATCH(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                outer.requests.append({"path": self.path, "headers": dict(self.headers), "body": body})
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                if status == 200:
                    metadata = dict(body["metadata"], uid="uid-1", generation=1)
                    self.wfile.write(json.dumps({**body, "metadata": metadata}).encode())
                else:
                    self.wfile.write(json.dumps({"message": "forbidden: cannot patch"}).encode())

            def log_message(self, *_args):
                pass

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.endpoint = f"http://127.0.0.1:{self.server.server_port}"

    def __enter__(self):
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *_exc):
        self.server.shutdown()
        self.server.server_close()


def environment(endpoint):
    return {
        "CLUSTER_ENDPOINT": endpoint,
        "CLUSTER_NAME": "management",
        "CLUSTER_CA_DATA": base64.b64encode(b"unused for http").decode(),
        "PROFILE_NAMESPACE": "runtime-conditions",
        "AWS_REGION": "eu-west-3",
    }


class BuildManifest(unittest.TestCase):
    def test_places_the_profile_in_the_namespace_and_records_the_image(self):
        manifest = apply_profile.build_manifest({"profile": PROFILE, "imageDigest": DIGEST}, "runtime-conditions")
        self.assertEqual(manifest["metadata"], {
            "name": "shipment-notifier",
            "namespace": "runtime-conditions",
            "annotations": {"demo.runtimeconditions.io/image": DIGEST},
        })
        self.assertEqual(manifest["workload"], PROFILE["workload"])
        self.assertEqual(manifest["conditions"], PROFILE["conditions"])

    def test_ignores_a_namespace_or_server_fields_supplied_by_the_caller(self):
        profile = {**PROFILE, "status": {"phase": "Ready"}, "metadata": {"name": "p", "namespace": "kube-system", "uid": "x"}}
        manifest = apply_profile.build_manifest({"profile": profile}, "runtime-conditions")
        self.assertEqual(manifest["metadata"], {"name": "p", "namespace": "runtime-conditions"})
        self.assertNotIn("status", manifest)

    def test_without_a_digest_no_image_annotation_is_claimed(self):
        profile = {**PROFILE, "metadata": {"name": "p", "annotations": {"demo.runtimeconditions.io/image": DIGEST, "keep": "me"}}}
        manifest = apply_profile.build_manifest({"profile": profile}, "ns")
        self.assertEqual(manifest["metadata"]["annotations"], {"keep": "me"})

    def test_rejects_unusable_requests(self):
        bad_events = [
            None,
            {},
            {"profile": "not an object"},
            {"profile": {**PROFILE, "kind": "ConfigMap"}},
            {"profile": {**PROFILE, "apiVersion": "v1"}},
            {"profile": {**PROFILE, "metadata": {}}},
            {"profile": {**PROFILE, "metadata": {"name": "Not_Valid"}}},
            {"profile": PROFILE, "imageDigest": "latest"},
            {"profile": PROFILE, "imageDigest": "sha256:ABC"},
            {"profile": PROFILE, "imageDigest": 7},
        ]
        for event in bad_events:
            with self.subTest(event=event), self.assertRaises(apply_profile.InvalidRequest):
                apply_profile.build_manifest(event, "ns")


class Handler(unittest.TestCase):
    def invoke(self, api, event):
        with mock.patch.dict(os.environ, environment(api.endpoint)):
            return apply_profile.handler(event, None, token_provider=lambda cluster, region: f"token-for-{cluster}-{region}")

    def test_applies_with_server_side_apply_and_returns_the_resource_identity(self):
        with FakeKubernetesApi() as api:
            result = self.invoke(api, {"profile": PROFILE, "imageDigest": DIGEST})

        self.assertEqual(result, {
            "name": "shipment-notifier", "namespace": "runtime-conditions", "uid": "uid-1", "generation": 1, "image": DIGEST,
        })
        [request] = api.requests
        parsed = urlparse(request["path"])
        self.assertEqual(parsed.path, "/apis/runtimeconditions.io/v1alpha1/namespaces/runtime-conditions/runtimeconditionsprofiles/shipment-notifier")
        self.assertEqual(parse_qs(parsed.query), {"fieldManager": ["profile-publisher"], "force": ["true"]})
        self.assertEqual(request["headers"]["Content-Type"], "application/apply-patch+yaml")
        self.assertEqual(request["headers"]["Authorization"], "Bearer token-for-management-eu-west-3")
        self.assertEqual(request["body"]["metadata"]["annotations"], {"demo.runtimeconditions.io/image": DIGEST})

    def test_two_profiles_are_applied_to_two_resources(self):
        other = {**PROFILE, "metadata": {"name": "orders"}}
        with FakeKubernetesApi() as api:
            self.invoke(api, {"profile": PROFILE})
            self.invoke(api, {"profile": other})
        paths = [urlparse(request["path"]).path.rsplit("/", 1)[1] for request in api.requests]
        self.assertEqual(paths, ["shipment-notifier", "orders"])

    def test_reports_the_api_servers_rejection(self):
        with FakeKubernetesApi(status=403) as api, self.assertRaisesRegex(RuntimeError, r"\(403\).*forbidden: cannot patch"):
            self.invoke(api, {"profile": PROFILE})

    def test_an_invalid_request_never_reaches_the_api(self):
        with FakeKubernetesApi() as api:
            with self.assertRaises(apply_profile.InvalidRequest):
                self.invoke(api, {"profile": {**PROFILE, "kind": "Other"}})
        self.assertEqual(api.requests, [])


class EksToken(unittest.TestCase):
    def test_is_a_presigned_identity_request_bound_to_the_cluster(self):
        credentials = {"AWS_ACCESS_KEY_ID": "AKIDEXAMPLE", "AWS_SECRET_ACCESS_KEY": "secret", "AWS_SESSION_TOKEN": "session"}
        with mock.patch.dict(os.environ, credentials):
            token = apply_profile.eks_token("management", "eu-west-3")

        self.assertTrue(token.startswith("k8s-aws-v1."))
        encoded = token.removeprefix("k8s-aws-v1.")
        url = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)).decode()
        query = parse_qs(urlparse(url).query)
        self.assertTrue(url.startswith("https://sts.eu-west-3.amazonaws.com/"))
        self.assertEqual(query["Action"], ["GetCallerIdentity"])
        self.assertIn("x-k8s-aws-id", query["X-Amz-SignedHeaders"][0])
        self.assertEqual(query["X-Amz-Expires"], ["60"])
        self.assertIn("X-Amz-Signature", query)


if __name__ == "__main__":
    unittest.main()
