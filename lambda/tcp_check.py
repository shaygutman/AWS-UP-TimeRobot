import os
import socket

import boto3

HOST = os.environ["TARGET_HOST"]
PORT = int(os.environ["TARGET_PORT"])
TIMEOUT_SECONDS = int(os.environ.get("TIMEOUT_SECONDS", "5"))
NAMESPACE = os.environ["METRIC_NAMESPACE"]
METRIC_NAME = os.environ["METRIC_NAME"]


def handler(event, context):
    port_open = 0
    try:
        with socket.create_connection((HOST, PORT), timeout=TIMEOUT_SECONDS):
            port_open = 1
    except OSError:
        port_open = 0

    boto3.client("cloudwatch").put_metric_data(
        Namespace=NAMESPACE,
        MetricData=[
            {
                "MetricName": METRIC_NAME,
                "Dimensions": [
                    {"Name": "Host", "Value": HOST},
                    {"Name": "Port", "Value": str(PORT)},
                ],
                "Value": port_open,
                "Unit": "Count",
            }
        ],
    )

    return {"host": HOST, "port": PORT, "open": port_open == 1}
