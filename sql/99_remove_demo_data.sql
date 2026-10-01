-- Removes the generated demo history (keeps real leads, settings, team and rules).
DELETE FROM leadops.inquiries WHERE is_demo;
DELETE FROM leadops.leads l WHERE l.is_demo AND NOT EXISTS (SELECT 1 FROM leadops.inquiries i WHERE i.lead_id = l.id);
