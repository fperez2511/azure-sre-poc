SELECT c.id, c.category, c.name, c.priceUsd, c.pricingUnit FROM c WHERE c.active = true ORDER BY c.priceUsd ASC
