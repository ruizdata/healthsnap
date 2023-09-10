-- PROCEDURE: public.newberry_script()

-- DROP PROCEDURE IF EXISTS public.newberry_script();

CREATE OR REPLACE PROCEDURE public.newberry_script(
	)
LANGUAGE 'sql'
AS $BODY$
/* Newberry Script

Set-Up

A.	Establish a connection to the VPN using L2TP and provide your username and password when prompted.
B.	In pgAdmin, navigate to the following location: Servers > HealthSnap Onboarding > Databases > healthsnap_onboarding > Schemas > public > Tables.
C.	Import the required files as CSV. For each file, create a table and name it accordingly. Add columns with data types set to "character varying". Ensure that the column titles exactly match the headers in the CSV files. Additionally, enable the "Header" option under the import settings.

Required Files: newberry_import,
				newberry_exclusions, 
				newberry_providers, 
				newberry_devices, 
				general_ccm_diagnoses_filters, 
				newberry_rpm_diagnoses_filters
*/

-- Please execute this code block manually to modify the structure of the table.

DO $$ 
DECLARE
    column_changes text[][];
    i int;
BEGIN
    column_changes := ARRAY[
        ['Patient Chart Nbr', 'mrn'],
        ['Pat First Name', 'first_name'],
        ['Pat Last Name', 'last_name'],
		['Pat Cv1 Plan Name', 'primary_insurance'],
        ['Pat Cv2 Plan Name', 'secondary_insurance'],
        ['Pat Home Phone', 'home_phone'],
		['Pat Home Phone Num', 'cell_phone'],
        ['Pat Email', 'email'],
        ['Pat Home Addr Line1', 'address_line1'],
        ['Pat Home Addr Line2', 'address_line2'],
        ['Pat Home Addr City', 'city'],
        ['Pat Home Addr St', 'state'],
        ['Pat Home Addr Zip', 'zip'],
		['Pat Assigned Prov First Name', 'provider_first_name'],
		['Pat Assigned Prov Last Name', 'provider_last_name']
    ];

    FOR i IN 1..array_length(column_changes, 1)
    LOOP
        IF EXISTS (SELECT * FROM information_schema.columns WHERE table_name = 'newberry_import' AND column_name = column_changes[i][1]) 
           AND NOT EXISTS (SELECT * FROM information_schema.columns WHERE table_name = 'newberry_import' AND column_name = column_changes[i][2]) THEN
            EXECUTE format('ALTER TABLE newberry_import RENAME COLUMN "%s" TO %I', column_changes[i][1], column_changes[i][2]);
        END IF;
    END LOOP;
END $$;

ALTER TABLE IF EXISTS newberry_import
ADD COLUMN IF NOT EXISTS "delete" BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS "provider_full_name" VARCHAR(255),
ADD COLUMN IF NOT EXISTS provider_email VARCHAR(255),
ADD COLUMN IF NOT EXISTS provider_signature VARCHAR(255),
ADD COLUMN IF NOT EXISTS enrollment_date VARCHAR(255),
ADD COLUMN IF NOT EXISTS combined_diagnoses VARCHAR(255),
ADD COLUMN IF NOT EXISTS ccm_filtered_diagnoses VARCHAR(255),
ADD COLUMN IF NOT EXISTS ccm_qualified VARCHAR(225),
ADD COLUMN IF NOT EXISTS rpm_filtered_diagnoses VARCHAR(255),
ADD COLUMN IF NOT EXISTS rpm_qualified VARCHAR(225),
ADD COLUMN IF NOT EXISTS rpm_monitoring_reason VARCHAR(225),
ADD COLUMN IF NOT EXISTS rpm_device VARCHAR(225),
ADD COLUMN IF NOT EXISTS rpm_data_point VARCHAR(225);

-- You can execute the entire code block provided below.

-- Delete MRNs already in the Exclusions list.

UPDATE newberry_import
SET delete = TRUE
WHERE "mrn" IN (
    SELECT "MRN" FROM newberry_exclusions
);

-- Delete duplicate MRNs.

UPDATE newberry_import
SET delete = TRUE
WHERE ctid NOT IN (
   SELECT min(ctid) 
   FROM newberry_import 
   GROUP BY "mrn"
);

-- Delete blank MRNs.

UPDATE newberry_import
SET delete = TRUE
WHERE "mrn" IS NULL OR TRIM("mrn") = '';

-- Delete patients whose primary insurance is not Medicare, Medicare Part A and B, or Medicare Part B.

UPDATE newberry_import
SET delete = TRUE
WHERE "primary_insurance" NOT LIKE 'MEDICARE%';

-- Delete patients whose secondary insurance contain Tricare, ChampVA, BCBS of South Carolina, or blank.

UPDATE newberry_import
SET delete = TRUE
WHERE "secondary_insurance" LIKE '%TRICARE%'
   OR "secondary_insurance" LIKE '%ChampVA%'
   OR "secondary_insurance" LIKE '%MEDICAID%'
   OR "secondary_insurance" LIKE '%BLUE CROSS BLUE SHIELD SC%'
   OR "secondary_insurance" IS NULL
   OR "secondary_insurance" = '';

-- Create a column for Combined Diagnoses.

UPDATE newberry_import
SET combined_diagnoses = concat("Pat Def Diag 1 Code", ',', "Pat Def Diag 2 Code", ',', "Pat Def Diag 3 Code", ',', "Pat Def Diag 4 Code", ',', "Pat Last Vst Diagnosis Codes");

UPDATE newberry_import
SET combined_diagnoses = regexp_replace(combined_diagnoses, ',+', ',', 'g');

UPDATE newberry_import
SET combined_diagnoses = REPLACE(combined_diagnoses, ' ', '');

UPDATE newberry_import
SET combined_diagnoses = (
    SELECT STRING_AGG(DISTINCT diagnosis, ', ' ORDER BY diagnosis)
    FROM (
        SELECT UNNEST(STRING_TO_ARRAY(REPLACE(combined_diagnoses, ' ', ''), ',')) AS diagnosis
    ) AS unique_diagnoses
);

-- Create a column for CCM Filtered Diagnoses.

UPDATE newberry_import
SET ccm_filtered_diagnoses = (
    SELECT STRING_AGG(DISTINCT general_ccm_diagnoses_filters."Diagnoses", ', ')
    FROM general_ccm_diagnoses_filters
    WHERE general_ccm_diagnoses_filters."Diagnoses" = ANY (STRING_TO_ARRAY(newberry_import.combined_diagnoses, ', '))
);

-- Create a column for CCM Qualified (at least 2 codes).

UPDATE newberry_import
SET ccm_qualified = 'CCM'
WHERE ccm_filtered_diagnoses LIKE '%,%';

-- Create a column for RPM Filtered Diagnoses.

UPDATE newberry_import
SET rpm_filtered_diagnoses = (
    SELECT STRING_AGG(DISTINCT newberry_rpm_diagnoses_filters."Diagnoses", ', ')
    FROM newberry_rpm_diagnoses_filters
    WHERE newberry_rpm_diagnoses_filters."Diagnoses" = ANY (STRING_TO_ARRAY(newberry_import.combined_diagnoses, ', '))
);

-- Create a column for RPM Qualified (at least 1 codes).

UPDATE newberry_import
SET rpm_qualified = 'RPM'
WHERE rpm_filtered_diagnoses IS NOT NULL;

-- For all RPM qualified, set monitoring reason, device, and data point.

UPDATE newberry_import
SET rpm_monitoring_reason = 'Monitoring Physiological Data'
WHERE rpm_qualified = 'RPM';

UPDATE newberry_import
SET rpm_data_point = (
    SELECT newberry_devices."Data Point"
    FROM newberry_devices
    WHERE newberry_devices."Diagnoses" = ANY (STRING_TO_ARRAY(newberry_import.rpm_filtered_diagnoses, ', '))
    LIMIT 1
);

UPDATE newberry_import
SET rpm_device = CASE 
    WHEN rpm_data_point = 'Blood Pressure' THEN 'Blood Pressure Monitor'
    WHEN rpm_data_point = 'Blood Glucose' THEN 'Glucose Meter'
    WHEN rpm_data_point = 'Oxygen Satuation' THEN 'Pulse Oximeter'
	ELSE rpm_device
END;

-- Delete patients who do not qualify for either CCM or RPM.

UPDATE newberry_import
SET delete = TRUE
WHERE (ccm_qualified IS NULL OR ccm_qualified = '')
  AND (rpm_qualified IS NULL OR rpm_qualified = '');

-- Make patients name proper case.

UPDATE newberry_import
SET "first_name" = UPPER(LEFT("first_name", 1)) || LOWER(SUBSTRING("first_name", 2)),
    "last_name" = UPPER(LEFT("last_name", 1)) || LOWER(SUBSTRING("last_name", 2));

-- Remove dashes from phone numbers.

UPDATE newberry_import
SET "home_phone" = REPLACE(REPLACE(REPLACE(REPLACE("home_phone", '(', ''), ')', ''), '-', ''), ' ', '');

-- If the home phone is misssing, use the mobile phone.

UPDATE newberry_import
SET "home_phone" = CASE
    WHEN "cell_phone" IS NOT NULL AND "cell_phone" <> '' THEN "cell_phone"
    ELSE "home_phone"
    END;

-- Fill blank patient emails using the format newberry+<MRN>@healthsnap.io.

UPDATE newberry_import
SET "email" = CONCAT('newberry+', "mrn", '@healthsnap.io')
WHERE "email" IS NULL OR "email" = '';

-- Add provider emails and signatures.

UPDATE newberry_import
SET provider_full_name = provider_first_name || ' ' || provider_last_name;

UPDATE newberry_import
SET provider_email = newberry_providers."Email",
    provider_signature = newberry_providers."Signature"
FROM newberry_providers
WHERE newberry_import.provider_full_name = newberry_providers."Name";

-- Set enrollment date to today.

UPDATE newberry_import
SET enrollment_date = CURRENT_DATE;

-- Select edited list.

SELECT *
FROM newberry_import;

$BODY$;

ALTER PROCEDURE public.newberry_script()
    OWNER TO rey;
