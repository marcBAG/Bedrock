exports.handler = async (event) => {
  const headers = {
    "Access-Control-Allow-Origin": "*",
    "Content-Type": "application/json",
  };

  if (event.httpMethod !== "POST") {
    return { statusCode: 405, headers, body: JSON.stringify({ error: "Method not allowed" }) };
  }

  const apiKey = process.env.ZAPRITE_API_KEY;
  if (!apiKey) {
    return { statusCode: 500, headers, body: JSON.stringify({ error: "Server configuration error" }) };
  }

  let body;
  try {
    body = JSON.parse(event.body);
  } catch {
    return { statusCode: 400, headers, body: JSON.stringify({ error: "Invalid request body" }) };
  }

  const { orderId, agreedAt } = body;
  if (!orderId || !agreedAt) {
    return { statusCode: 400, headers, body: JSON.stringify({ error: "Missing required fields" }) };
  }

  // Validate order ID format
  if (!orderId.startsWith("od_") && !orderId.startsWith("odp_")) {
    return { statusCode: 400, headers, body: JSON.stringify({ error: "Invalid orderId format" }) };
  }

  try {
    // First check if already onboarded
    const getResponse = await fetch(`https://api.zaprite.com/v1/orders/${orderId}`, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });

    if (!getResponse.ok) {
      return { statusCode: 404, headers, body: JSON.stringify({ error: "Order not found" }) };
    }

    const order = await getResponse.json();

    if (order.metadata?.onboarded === "true") {
      return { statusCode: 409, headers, body: JSON.stringify({ error: "Already onboarded" }) };
    }

    // Write onboarded flag to order metadata
    const updateResponse = await fetch(`https://api.zaprite.com/v1/orders/${orderId}`, {
      method: "PATCH",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        metadata: {
          ...order.metadata,
          onboarded: "true",
          onboardedAt: agreedAt,
        },
      }),
    });

    if (!updateResponse.ok) {
      return { statusCode: 502, headers, body: JSON.stringify({ error: "Failed to update order" }) };
    }

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({ success: true }),
    };
  } catch (err) {
    return { statusCode: 502, headers, body: JSON.stringify({ error: "Failed to reach payment provider" }) };
  }
};
