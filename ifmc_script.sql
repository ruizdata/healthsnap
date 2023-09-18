-- PROCEDURE: public.ifmc_script()

-- DROP PROCEDURE IF EXISTS public.ifmc_script();

CREATE OR REPLACE PROCEDURE public.ifmc_script(
	)
LANGUAGE 'sql'
AS $BODY$
/* Integrated Family Health Center - Script

Set-Up

A.	Establish a connection to the VPN using L2TP and provide your username and password when prompted.
B.	In pgAdmin, navigate to the following location: Servers > HealthSnap Onboarding > Databases > healthsnap_onboarding > Schemas > public > Tables.
C.	Import the required files as CSV. For each file, create a table and name it accordingly. Add columns with data types set to "character varying". Ensure that the column titles exactly match the headers in the CSV files. Additionally, enable the "Header" option under the import settings.

Required Files: ifmc_import,
				ifmc_diagnoses,
				ifmc_exclusions, 
				ifmc_providers, 
				ifmc_devices, 
				general_ccm_filtered_diagnoses, 
				ifmc_rpm_filtered_diagnoses
*/

-- Please execute this code block manually to modify the structure of the table.

DO $$ 
DECLARE
    column_changes text[][];
    i int;
BEGIN
    column_changes := ARRAY[
        ['Patient Acct No', 'mrn'],
        ['Patient First Name', 'first_name'],
        ['Patient Last Name', 'last_name'],
		['Primary Insurance Name', 'primary_insurance'],
        ['Secondary Insurance Name', 'secondary_insurance'],
        ['Patient Home Phone', 'home_phone'],
		['Patient Cell Phone', 'cell_phone'],
        ['Patient E-mail', 'email'],
        ['Patient Address Line 1', 'address_line1'],
        ['Patient Address Line 2', 'address_line2'],
        ['Patient City', 'city'],
        ['Patient State', 'state'],
        ['Patient ZIP Code', 'zip'],
		['Appointment Provider Name', 'provider_name']
    ];

    FOR i IN 1..array_length(column_changes, 1)
    LOOP
        IF EXISTS (SELECT * FROM information_schema.columns WHERE table_name = 'ifmc_import' AND column_name = column_changes[i][1]) 
           AND NOT EXISTS (SELECT * FROM information_schema.columns WHERE table_name = 'ifmc_import' AND column_name = column_changes[i][2]) THEN
            EXECUTE format('ALTER TABLE ifmc_import RENAME COLUMN "%s" TO %I', column_changes[i][1], column_changes[i][2]);
        END IF;
    END LOOP;
END $$;

ALTER TABLE IF EXISTS ifmc_import
ADD COLUMN IF NOT EXISTS "delete" BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS "provider_full_name" VARCHAR(255),
ADD COLUMN IF NOT EXISTS provider_email VARCHAR(255),
ADD COLUMN IF NOT EXISTS provider_signature VARCHAR(255),
ADD COLUMN IF NOT EXISTS enrollment_date VARCHAR(255),
ADD COLUMN IF NOT EXISTS combined_diagnoses VARCHAR(10000),
ADD COLUMN IF NOT EXISTS ccm_filtered_diagnoses VARCHAR(255),
ADD COLUMN IF NOT EXISTS ccm_qualified VARCHAR(225),
ADD COLUMN IF NOT EXISTS rpm_filtered_diagnoses VARCHAR(255),
ADD COLUMN IF NOT EXISTS rpm_qualified VARCHAR(225),
ADD COLUMN IF NOT EXISTS rpm_monitoring_reason VARCHAR(225),
ADD COLUMN IF NOT EXISTS rpm_device VARCHAR(225),
ADD COLUMN IF NOT EXISTS rpm_data_point VARCHAR(225);

-- You can execute the entire code block provided below.

-- Delete MRNs already in the Exclusions list.

UPDATE ifmc_import
SET delete = TRUE
WHERE "mrn" IN (
    SELECT "MRN" FROM ifmc_exclusions
);

-- Delete duplicate MRNs.

UPDATE ifmc_import
SET delete = TRUE
WHERE ctid NOT IN (
   SELECT min(ctid) 
   FROM cobb_import 
   GROUP BY "mrn"
);

-- Delete blank MRNs.

UPDATE ifmc_import
SET delete = TRUE
WHERE "mrn" IS NULL OR TRIM("mrn") = '';

-- Delete patients whose primary insurance is not Medicare, Medicare Part A and B, or Medicare Part B.

UPDATE ifmc_import
SET delete = TRUE
WHERE NOT (primary_insurance = 'MEDICARE' OR primary_insurance = 'Medicare Railroad');

-- Delete patients whose Appointment Facility Name is not IFMC.

UPDATE ifmc_import
SET delete = TRUE
WHERE NOT "Appointment Facility Name" = 'Integrated Family Medical Center';

-- Create a column for Combined Diagnoses.

UPDATE ifmc_import
SET combined_diagnoses = ifmc_diagnoses.combined
FROM (
    SELECT "MRN", STRING_AGG("Code", ',') AS combined
    FROM ifmc_diagnoses
    GROUP BY "MRN"
) AS ifmc_diagnoses
WHERE ifmc_import.mrn = ifmc_diagnoses."MRN";

UPDATE ifmc_import
SET combined_diagnoses = regexp_replace(combined_diagnoses, ',+', ',', 'g');

UPDATE ifmc_import
SET combined_diagnoses = REPLACE(combined_diagnoses, ' ', '');

UPDATE ifmc_import
SET combined_diagnoses = (
    SELECT STRING_AGG(DISTINCT diagnosis, ', ' ORDER BY diagnosis)
    FROM (
        SELECT UNNEST(STRING_TO_ARRAY(REPLACE(combined_diagnoses, ' ', ''), ',')) AS diagnosis
    ) AS unique_diagnoses
);

-- Create a column for CCM Filtered Diagnoses.

UPDATE ifmc_import
SET ccm_filtered_diagnoses = (
    SELECT STRING_AGG(DISTINCT general_ccm_diagnoses_filters."Diagnoses", ', ')
    FROM general_ccm_diagnoses_filters
    WHERE general_ccm_diagnoses_filters."Diagnoses" = ANY (STRING_TO_ARRAY(ifmc_import.combined_diagnoses, ', '))
);

-- Create a column for CCM Qualified (at least 2 codes).

UPDATE ifmc_import
SET ccm_qualified = 'CCM'
WHERE ccm_filtered_diagnoses LIKE '%,%';

-- Create a column for RPM Filtered Diagnoses.

UPDATE ifmc_import
SET rpm_filtered_diagnoses = (
    SELECT STRING_AGG(DISTINCT ifmc_rpm_diagnoses_filters."Diagnoses", ', ')
    FROM ifmc_rpm_diagnoses_filters
    WHERE ifmc_rpm_diagnoses_filters."Diagnoses" = ANY (STRING_TO_ARRAY(ifmc_import.combined_diagnoses, ', '))
);

-- Create a column for RPM Qualified (at least 1 codes).

UPDATE ifmc_import
SET rpm_qualified = 'RPM'
WHERE rpm_filtered_diagnoses IS NOT NULL;

-- For all RPM qualified, set monitoring reason, device, and data point.

UPDATE ifmc_import
SET rpm_monitoring_reason = 'Monitoring Physiological Data'
WHERE rpm_qualified = 'RPM';

UPDATE ifmc_import
SET rpm_device = (
    SELECT ifmc_devices."Devices"
    FROM ifmc_devices
    WHERE ifmc_devices."Diagnoses" = ANY (STRING_TO_ARRAY(ifmc_import.rpm_filtered_diagnoses, ', '))
    LIMIT 1
);

UPDATE ifmc_import
SET rpm_data_point = CASE 
    WHEN rpm_device = 'Blood Pressure Monitor' THEN 'Blood Pressure'
    WHEN rpm_device = 'Glucose Meter' THEN 'Blood Glucose'
    WHEN rpm_device = 'Pulse Oximeter' THEN 'Oxygen Saturation'
	ELSE rpm_data_point
END;

-- Delete patients who do not qualify for either CCM or RPM.

UPDATE ifmc_import
SET delete = TRUE
WHERE (ccm_qualified IS NULL OR ccm_qualified = '')
  AND (rpm_qualified IS NULL OR rpm_qualified = '');

-- Make patients name proper case.

UPDATE ifmc_import
SET "first_name" = UPPER(LEFT("first_name", 1)) || LOWER(SUBSTRING("first_name", 2)),
    "last_name" = UPPER(LEFT("last_name", 1)) || LOWER(SUBSTRING("last_name", 2));

-- Remove dashes from phone numbers.

UPDATE ifmc_import
SET "home_phone" = REPLACE("home_phone", '-', '');

UPDATE ifmc_import
SET "cell_phone" = REPLACE("cell_phone", '-', '');

-- If the home phone is misssing, use the mobile phone.

UPDATE ifmc_import
SET "home_phone" = CASE
    WHEN "cell_phone" IS NOT NULL AND "cell_phone" <> '' THEN "cell_phone"
    ELSE "home_phone"
    END;

-- Fill blank patient emails using the format ifmc+<MRN>@healthsnap.io.

UPDATE ifmc_import
SET "email" = CONCAT('ifmc+', "mrn", '@healthsnap.io')
WHERE "email" IS NULL OR "email" = '';

-- Set enrollment date to today.

UPDATE ifmc_import
SET enrollment_date = CURRENT_DATE;

-- Select edited list.

SELECT *
FROM ifmc_import
WHERE delete = FALSE;

-- Clear delete column

UPDATE ifmc_import
SET delete = FALSE;

-- Test Zone

$BODY$;

ALTER PROCEDURE public.ifmc_script()
    OWNER TO rey;
