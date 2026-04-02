const FORM_ID = "69ce5d845108a8000883a763";

async function checkOnboarded(orderId) {
  try {
    const netlifyToken = process.env.NETLIFY_API_TOKEN;
    if (!netlifyToken) return false;
    const response = await fetch(
      `https://api.netlify.com/api/v1/forms/${FORM_ID}/submissions`,
      { headers: { Authorization: `Bearer ${netlifyToken}` } }
    );
    if (!response.ok) return false;
    const submissions = await response.json();
    return submissions.some(s => s.data?.orderId === orderId);
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
