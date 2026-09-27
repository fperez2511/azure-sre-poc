SELECT c.category, COUNT(1) AS bookings, SUM(c.totalPriceUsd) AS revenueUsd FROM c GROUP BY c.category
