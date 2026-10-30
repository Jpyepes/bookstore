import { SendMessageCommand, SQSClient } from "@aws-sdk/client-sqs";

import { config } from "../config/env.js";
import { logger } from "../config/logger.js";

export const ORDER_PLACED_EVENT = "order.placed";

const ORDER_EVENT_SCHEMA_VERSION = 1;

// Credentials come from the default provider chain (EC2 instance profile in AWS)
const sqsClient = config.orderEvents.enabled
  ? new SQSClient({ region: config.orderEvents.region })
  : null;

// Publishes after the order transaction has committed. Publishing is
// best-effort: a failure is logged and never undoes a placed order.
export const publishOrderPlaced = async ({ order, items }) => {
  if (!sqsClient) {
    return;
  }

  const event = {
    eventType: ORDER_PLACED_EVENT,
    schemaVersion: ORDER_EVENT_SCHEMA_VERSION,
    occurredAt: new Date().toISOString(),
    order: {
      orderId: order.order_id,
      customerId: order.customer_id,
      status: order.order_status,
      totalAmount: order.total_amount,
      totalQuantity: order.total_quantity,
      orderTimestamp: order.order_timestamp,
      items: items.map((item) => ({
        bookId: item.bookId,
        quantity: item.quantity,
      })),
    },
  };

  try {
    const result = await sqsClient.send(
      new SendMessageCommand({
        QueueUrl: config.orderEvents.queueUrl,
        MessageBody: JSON.stringify(event),
        MessageAttributes: {
          eventType: {
            DataType: "String",
            StringValue: ORDER_PLACED_EVENT,
          },
        },
      })
    );

    logger.info("Order event published", {
      eventType: ORDER_PLACED_EVENT,
      orderId: order.order_id,
      messageId: result.MessageId,
    });
  } catch (error) {
    logger.error("Order event could not be published", {
      eventType: ORDER_PLACED_EVENT,
      orderId: order.order_id,
      error: error.message,
    });
  }
};
