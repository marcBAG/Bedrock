const { getStore } = require("@netlify/blobs");

async function checkOnboarded(orderId) {
  try {
    const store = getStore("onboarding");
    const existing = await store.get(orderId);
    return !!existing;
  } catch {
    return false;
  }
}

exports.handler = async (event) => {
  const headers = {
    "Access-Control-Allow-Origin": "*",
    "Content-Type": "application/json",
  };

  // Only allow GET
  if (event.httpMethod !== "GET") {
    return { statusCode: 405, headers, body: JSON.stringify({ error: "Method not allowed" }) };
  }

  const orderId = event.queryStringParameters?.orderId;
  if (!orderId) {
    return { statusCode: 400, headers, body: JSON.stringify({ error: "Missing orderId" }) };
  }

  // Basic validation -- Zaprite order IDs start with "od_" or "odp_"
  if (!orderId.startsWith("od_") && !orderId.startsWith("odp_")) {
    return { statusCode: 400, headers, body: JSON.stringify({ error: "Invalid orderId format" }) };
  }

  const apiKey = process.env.ZAPRITE_API_KEY;
  if (!apiKey) {
    return { statusCode: 500, headers, body: JSON.stringify({ error: "Server configuration error" }) };
  }

  try {
    const response = await fetch(`https://api.zaprite.com/v1/orders/${orderId}`, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });

    if (!response.ok) {
      return {
        statusCode: response.status === 404 ? 404 : 502,
        headers,
        body: JSON.stringify({ error: response.status === 404 ? "Order not found" : "Payment provider error" }),
      };
    }

    const order = await response.json();

    // Return only what the onboarding page needs -- nothing sensitive
    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({
        name: order.customerData?.name || "",
        email: order.customerData?.email || "",
        orderId: orderId,
        amount: order.totalAmount,
        currency: order.currency,
        status: order.status,
        onboarded: await checkOnboarded(orderId),
      }),
    };
  } catch (err) {
    return { statusCode: 502, headers, body: JSON.stringify({ error: "Failed to reach payment provider" }) };
  }
};
