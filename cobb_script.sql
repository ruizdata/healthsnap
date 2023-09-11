-- PROCEDURE: public.cobb_script()

-- DROP PROCEDURE IF EXISTS public.cobb_script();

CREATE OR REPLACE PROCEDURE public.cobb_script(
	)
LANGUAGE 'sql'
AS $BODY$
/* Cobb Nephrology Script

Set-Up

A.	Establish a connection to the VPN using L2TP and provide your username and password when prompted.
B.	In pgAdmin, navigate to the following location: Servers > HealthSnap Onboarding > Databases > healthsnap_onboarding > Schemas > public > Tables.
C.	Import the required files as CSV. For each file, create a table and name it accordingly. Add columns with data types set to "character varying". Ensure that the column titles exactly match the headers in the CSV files. Additionally, enable the "Header" option under the import settings.

Required Files: cobb_import,
				cobb_exclusions, 
				cobb_providers, 
				cobb_devices, 
				general_ccm_filtered_diagnoses, 
				cobb_rpm_filtered_diagnoses
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
        IF EXISTS (SELECT * FROM information_schema.columns WHERE table_name = 'cobb_import' AND column_name = column_changes[i][1]) 
           AND NOT EXISTS (SELECT * FROM information_schema.columns WHERE table_name = 'cobb_import' AND column_name = column_changes[i][2]) THEN
            EXECUTE format('ALTER TABLE cobb_import RENAME COLUMN "%s" TO %I', column_changes[i][1], column_changes[i][2]);
        END IF;
    END LOOP;
END $$;

ALTER TABLE IF EXISTS cobb_import
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

UPDATE cobb_import
SET delete = TRUE
WHERE "mrn" IN (
    SELECT "MRN" FROM cobb_exclusions
);

-- Delete duplicate MRNs.

UPDATE cobb_import
SET delete = TRUE
WHERE ctid NOT IN (
   SELECT min(ctid) 
   FROM cobb_import 
   GROUP BY "mrn"
);

-- Delete blank MRNs.

UPDATE cobb_import
SET delete = TRUE
WHERE "mrn" IS NULL OR TRIM("mrn") = '';

-- Delete patients whose primary insurance is not Medicare, Medicare Part A and B, or Medicare Part B.

UPDATE cobb_import
SET delete = TRUE
WHERE "primary_insurance" NOT LIKE 'Medicare%';

-- Delete patients whose secondary insurance contain Tricare, ChampVA, BCBS of South Carolina, or blank.

UPDATE cobb_import
SET delete = TRUE
WHERE "secondary_insurance" LIKE '%Tricare%'
   OR "secondary_insurance" LIKE 'ChampVA%'
   OR "secondary_insurance" LIKE 'Medicaid%'
   OR "secondary_insurance" LIKE 'MEDICAID%'
   OR "secondary_insurance" LIKE '%BLUE CROSS BLUE SHIELD SC%'
   OR "secondary_insurance" IS NULL
   OR "secondary_insurance" = '';

-- Delete patients POS is not 11.

UPDATE cobb_import
SET delete = TRUE
WHERE "Appointment Facility POS" NOT LIKE '11';

-- Create a column for Combined Diagnoses.

UPDATE cobb_import
SET combined_diagnoses = cobb_diagnoses.combined
FROM (
    SELECT "MRN", STRING_AGG("Code", ',') AS combined
    FROM cobb_diagnoses
    GROUP BY "MRN"
) AS cobb_diagnoses
WHERE cobb_import.mrn = cobb_diagnoses."MRN";

UPDATE cobb_import
SET combined_diagnoses = regexp_replace(combined_diagnoses, ',+', ',', 'g');

UPDATE cobb_import
SET combined_diagnoses = REPLACE(combined_diagnoses, ' ', '');

UPDATE cobb_import
SET combined_diagnoses = (
    SELECT STRING_AGG(DISTINCT diagnosis, ', ' ORDER BY diagnosis)
    FROM (
        SELECT UNNEST(STRING_TO_ARRAY(REPLACE(combined_diagnoses, ' ', ''), ',')) AS diagnosis
    ) AS unique_diagnoses
);

-- Create a column for CCM Filtered Diagnoses.

UPDATE cobb_import
SET ccm_filtered_diagnoses = (
    SELECT STRING_AGG(DISTINCT general_ccm_diagnoses_filters."Diagnoses", ', ')
    FROM general_ccm_diagnoses_filters
    WHERE general_ccm_diagnoses_filters."Diagnoses" = ANY (STRING_TO_ARRAY(cobb_import.combined_diagnoses, ', '))
);

-- Create a column for CCM Qualified (at least 2 codes).

UPDATE cobb_import
SET ccm_qualified = 'CCM'
WHERE ccm_filtered_diagnoses LIKE '%,%';

-- Create a column for RPM Filtered Diagnoses.

UPDATE cobb_import
SET rpm_filtered_diagnoses = (
    SELECT STRING_AGG(DISTINCT cobb_rpm_diagnoses_filters."Diagnoses", ', ')
    FROM cobb_rpm_diagnoses_filters
    WHERE cobb_rpm_diagnoses_filters."Diagnoses" = ANY (STRING_TO_ARRAY(cobb_import.combined_diagnoses, ', '))
);

-- Create a column for RPM Qualified (at least 1 codes).

UPDATE cobb_import
SET rpm_qualified = 'RPM'
WHERE rpm_filtered_diagnoses IS NOT NULL;

-- For all RPM qualified, set monitoring reason, device, and data point.

UPDATE cobb_import
SET rpm_monitoring_reason = 'Monitoring Physiological Data'
WHERE rpm_qualified = 'RPM';

UPDATE cobb_import
SET rpm_device = (
    SELECT cobb_devices."Devices"
    FROM cobb_devices
    WHERE cobb_devices."Diagnoses" = ANY (STRING_TO_ARRAY(cobb_import.rpm_filtered_diagnoses, ', '))
    LIMIT 1
);

UPDATE cobb_import
SET rpm_data_point = CASE 
    WHEN rpm_device = 'Blood Pressure Monitor' THEN 'Blood Pressure'
    WHEN rpm_device = 'Glucose Meter' THEN 'Blood Glucose'
    WHEN rpm_device = 'Pulse Oximeter' THEN 'Oxygen Saturation'
	ELSE rpm_data_point
END;

-- Delete patients who do not qualify for either CCM or RPM.

UPDATE cobb_import
SET delete = TRUE
WHERE (ccm_qualified IS NULL OR ccm_qualified = '')
  AND (rpm_qualified IS NULL OR rpm_qualified = '');

-- Make patients name proper case.

UPDATE cobb_import
SET "first_name" = UPPER(LEFT("first_name", 1)) || LOWER(SUBSTRING("first_name", 2)),
    "last_name" = UPPER(LEFT("last_name", 1)) || LOWER(SUBSTRING("last_name", 2));

-- Remove dashes from phone numbers.

UPDATE cobb_import
SET "home_phone" = REPLACE(REPLACE(REPLACE(REPLACE("home_phone", '(', ''), ')', ''), '-', ''), ' ', '');

-- If the home phone is misssing, use the mobile phone.

UPDATE cobb_import
SET "home_phone" = CASE
    WHEN "cell_phone" IS NOT NULL AND "cell_phone" <> '' THEN "cell_phone"
    ELSE "home_phone"
    END;

-- Fill blank patient emails using the format newberry+<MRN>@healthsnap.io.

UPDATE cobb_import
SET "email" = CONCAT('cobbnephrology+', "mrn", '@healthsnap.io')
WHERE "email" IS NULL OR "email" = '';

-- Set enrollment date to today.

UPDATE newberry_import
SET enrollment_date = CURRENT_DATE;

-- Select edited list.

SELECT *
FROM cobb_import
WHERE delete = FALSE;

-- Clear delete column

UPDATE cobb_import
SET delete = FALSE;

$BODY$;

ALTER PROCEDURE public.cobb_script()
    OWNER TO rey;
