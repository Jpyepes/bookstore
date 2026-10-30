"""Consume "order.placed" events from SQS and send an e-mail notification via SNS.

Trigger: SQS queue bookstore-order-placed (event source mapping with
ReportBatchItemFailures). Only the failed messages of a batch are retried;
after 5 failed receives SQS moves a message to bookstore-order-placed-dlq.
"""

import json
import logging
import os
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import boto3

TOPIC_ARN = os.environ["ORDER_NOTIFICATIONS_TOPIC_ARN"]
ORDER_PLACED_EVENT = "order.placed"

# Colombia does not observe daylight saving time
BOGOTA_TZ = timezone(timedelta(hours=-5))

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sns = boto3.client("sns")


def format_cop(amount):
    """Format an amount as Colombian pesos, e.g. 319800.00 -> $319.800."""
    return "$" + f"{Decimal(str(amount)):,.0f}".replace(",", ".")


def format_timestamp(iso_timestamp):
    moment = datetime.fromisoformat(iso_timestamp.replace("Z", "+00:00"))
    return moment.astimezone(BOGOTA_TZ).strftime("%Y-%m-%d %H:%M:%S (hora Colombia)")


def build_notification(order):
    """Return the (subject, message) pair for an order.placed event."""
    order_id = order["orderId"]
    item_lines = "\n".join(
        f"  - Libro {item['bookId']}  x{item['quantity']}" for item in order["items"]
    )

    subject = f"BookStore Co. - Nueva orden {order_id[:8]}"
    message = (
        "Se ha registrado una nueva orden de compra en BookStore Co.\n"
        "\n"
        f"Orden:        {order_id}\n"
        f"Cliente:      {order['customerId']}\n"
        f"Estado:       {order['status']}\n"
        f"Fecha:        {format_timestamp(order['orderTimestamp'])}\n"
        f"Unidades:     {order['totalQuantity']}\n"
        f"Total:        {format_cop(order['totalAmount'])} COP\n"
        "\n"
        "Detalle:\n"
        f"{item_lines}\n"
    )

    return subject, message


def handler(event, context):
    failures = []

    for record in event["Records"]:
        message_id = record["messageId"]

        try:
            body = json.loads(record["body"])

            if body.get("eventType") != ORDER_PLACED_EVENT:
                logger.warning("Skipping message %s with unexpected eventType %r",
                               message_id, body.get("eventType"))
                continue

            subject, message = build_notification(body["order"])
            sns.publish(TopicArn=TOPIC_ARN, Subject=subject, Message=message)

            logger.info("Notification sent for order %s (message %s)",
                        body["order"]["orderId"], message_id)

        except Exception:
            logger.exception("Could not process message %s", message_id)
            failures.append({"itemIdentifier": message_id})

    return {"batchItemFailures": failures}
