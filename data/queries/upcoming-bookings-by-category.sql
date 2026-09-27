SELECT c.id, c.customerId, c.offeringName, c.attendees, c.startTimeUtc FROM c WHERE c.category = @category AND c.startTimeUtc >= @fromUtc ORDER BY c.category ASC, c.startTimeUtc ASC
