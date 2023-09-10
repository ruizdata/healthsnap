-- PROCEDURE: public.dfl_script()

-- DROP PROCEDURE IF EXISTS public.dfl_script();

CREATE OR REPLACE PROCEDURE public.dfl_script(
	)
LANGUAGE 'sql'
AS $BODY$
/* DFL Script

Set-Up

A.	Establish a connection to the VPN using L2TP and provide your username and password when prompted.
B.	In pgAdmin, navigate to the following location: Servers > HealthSnap Onboarding > Databases > healthsnap_onboarding > Schemas > public > Tables.
C.	Import the required files as CSV. For each file, create a table and name it accordingly. Add columns with data types set to "character varying". Ensure that the column titles exactly match the headers in the CSV files. Additionally, enable the "Header" option under the import settings.

Required Files: dfl_import,
				dfl_diagnoses,
				dfl_exclusions, 
				dfl_providers, 
				dfl_devices, 
				dfl_ccm_diagnoses_filters, 
				dfl_rpm_diagnoses_filters
*/

-- Please execute this code block manually to modify the structure of the table.

DO $$ 
DECLARE
    column_changes text[][];
    i int;
BEGIN
    column_changes := ARRAY[
        ['Patient Account Number', 'mrn'],
        ['Patient Name', 'patient_name'],
		['Primary Insurance Name', 'primary_insurance'],
        ['Secondary Insurance Name', 'secondary_insurance'],
        ['Patient Home Phone', 'home_phone'],
		['Patient Cell Phone', 'cell_phone'],
        ['Patient Email', 'email'],
        ['Patient Full Address', 'full_address'],
		['Appointment Provider Name', 'provider_name']
    ];

    FOR i IN 1..array_length(column_changes, 1)
    LOOP
        IF EXISTS (SELECT * FROM information_schema.columns WHERE table_name = 'dfl_import' AND column_name = column_changes[i][1]) 
           AND NOT EXISTS (SELECT * FROM information_schema.columns WHERE table_name = 'dfl_import' AND column_name = column_changes[i][2]) THEN
            EXECUTE format('ALTER TABLE dfl_import RENAME COLUMN "%s" TO %I', column_changes[i][1], column_changes[i][2]);
        END IF;
    END LOOP;
END $$;

ALTER TABLE IF EXISTS dfl_import
ADD COLUMN IF NOT EXISTS "delete" BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS "provider_full_name" VARCHAR(255),
ADD COLUMN IF NOT EXISTS provider_email VARCHAR(255),
ADD COLUMN IF NOT EXISTS provider_signature VARCHAR(255),
ADD COLUMN IF NOT EXISTS enrollment_date VARCHAR(255),
ADD COLUMN IF NOT EXISTS combined_diagnoses VARCHAR(2000),
ADD COLUMN IF NOT EXISTS ccm_filtered_diagnoses VARCHAR(255),
ADD COLUMN IF NOT EXISTS ccm_qualified VARCHAR(225),
ADD COLUMN IF NOT EXISTS rpm_filtered_diagnoses VARCHAR(255),
ADD COLUMN IF NOT EXISTS rpm_qualified VARCHAR(225),
ADD COLUMN IF NOT EXISTS rpm_monitoring_reason VARCHAR(225),
ADD COLUMN IF NOT EXISTS rpm_device VARCHAR(225),
ADD COLUMN IF NOT EXISTS rpm_data_point VARCHAR(225);

-- You can execute the entire code block provided below.

-- Delete MRNs already in the Exclusions list.

UPDATE dfl_import
SET delete = TRUE
WHERE "mrn" IN (
    SELECT "MRN" FROM dfl_exclusions
);

-- Delete duplicate MRNs.

UPDATE dfl_import
SET delete = TRUE
WHERE ctid NOT IN (
   SELECT min(ctid) 
   FROM dfl_import 
   GROUP BY "mrn"
);

-- Delete blank MRNs.

UPDATE dfl_import
SET delete = TRUE
WHERE "mrn" IS NULL OR TRIM("mrn") = '';

-- Delete patients whose primary insurance is not Medicare, Medicare Part A and B, or Medicare Part B.

UPDATE dfl_import
SET delete = TRUE
WHERE "primary_insurance" NOT LIKE 'MCR MEDICARE%';

-- Delete patients whose secondary insurance is blank.

UPDATE dfl_import
SET delete = TRUE
WHERE "secondary_insurance" IS NULL
   OR "secondary_insurance" = '';

-- Create a column for Combined Diagnoses.

UPDATE dfl_import
SET combined_diagnoses = dfl_diagnoses.combined
FROM (
    SELECT "MRN", STRING_AGG("Code", ',') AS combined
    FROM dfl_diagnoses
    GROUP BY "MRN"
) AS dfl_diagnoses
WHERE dfl_import.mrn = dfl_diagnoses."MRN";

UPDATE dfl_import
SET combined_diagnoses = regexp_replace(combined_diagnoses, ',+', ',', 'g');

UPDATE dfl_import
SET combined_diagnoses = REPLACE(combined_diagnoses, ' ', '');

UPDATE dfl_import
SET combined_diagnoses = (
    SELECT STRING_AGG(DISTINCT diagnosis, ', ' ORDER BY diagnosis)
    FROM (
        SELECT UNNEST(STRING_TO_ARRAY(REPLACE(combined_diagnoses, ' ', ''), ',')) AS diagnosis
    ) AS unique_diagnoses
);

-- Create a column for CCM Filtered Diagnoses.

UPDATE dfl_import
SET ccm_filtered_diagnoses = (
    SELECT STRING_AGG(DISTINCT general_ccm_diagnoses_filters."Diagnoses", ', ')
    FROM general_ccm_diagnoses_filters
    WHERE general_ccm_diagnoses_filters."Diagnoses" = ANY (STRING_TO_ARRAY(dfl_import.combined_diagnoses, ', '))
);

-- Create a column for CCM Qualified (at least 2 codes).

UPDATE dfl_import
SET ccm_qualified = 'CCM'
WHERE ccm_filtered_diagnoses LIKE '%,%';

-- Create a column for RPM Filtered Diagnoses.

UPDATE dfl_import
SET rpm_filtered_diagnoses = (
    SELECT STRING_AGG(DISTINCT dfl_rpm_diagnoses_filters."Diagnoses", ', ')
    FROM dfl_rpm_diagnoses_filters
    WHERE dfl_rpm_diagnoses_filters."Diagnoses" = ANY (STRING_TO_ARRAY(dfl_import.combined_diagnoses, ', '))
);

-- Create a column for RPM Qualified (at least 1 codes).

UPDATE dfl_import
SET rpm_qualified = 'RPM'
WHERE rpm_filtered_diagnoses IS NOT NULL;

-- For all RPM qualified, set monitoring reason, device, and data point.

UPDATE dfl_import
SET rpm_monitoring_reason = 'Monitoring Physiological Data'
WHERE rpm_qualified = 'RPM';

UPDATE dfl_import
SET rpm_device = (
    SELECT dfl_devices."Devices"
    FROM dfl_devices
    WHERE dfl_devices."Diagnoses" = ANY (STRING_TO_ARRAY(dfl_import.rpm_filtered_diagnoses, ', '))
    LIMIT 1
);

UPDATE dfl_import
SET rpm_data_point = CASE 
    WHEN rpm_device = 'Blood Pressure Monitor' THEN 'Blood Pressure'
    WHEN rpm_device = 'Glucose Meter' THEN 'Blood Glucose'
    WHEN rpm_device = 'Pulse Oximeter' THEN 'Oxygen Saturation'
	ELSE rpm_data_point
END;

-- Delete patients who do not qualify for either CCM or RPM.

UPDATE dfl_import
SET delete = TRUE
WHERE (ccm_qualified IS NULL OR ccm_qualified = '')
  AND (rpm_qualified IS NULL OR rpm_qualified = '');

-- Remove dashes from phone numbers.

UPDATE dfl_import
SET "home_phone" = REPLACE(REPLACE(REPLACE(REPLACE("home_phone", '(', ''), ')', ''), '-', ''), ' ', '');

-- If the home phone is misssing, use the mobile phone.

UPDATE dfl_import
SET "home_phone" = CASE
    WHEN "cell_phone" IS NOT NULL AND "cell_phone" <> '' THEN "cell_phone"
    ELSE "home_phone"
    END;

-- Fill blank patient emails using the format newberry+<MRN>@healthsnap.io.

UPDATE dfl_import
SET "email" = CONCAT('dfl+', "mrn", '@healthsnap.io')
WHERE "email" IS NULL OR "email" = '';

-- Add provider emails.

UPDATE dfl_import
SET provider_full_name = 'Cheryl Sarmiento',
    provider_email = 'drcheryl@drforlife.com';

-- Set enrollment date to today.

UPDATE dfl_import
SET enrollment_date = CURRENT_DATE;

-- Select edited list.

SELECT *
FROM dfl_import
WHERE delete = FALSE;

$BODY$;

ALTER PROCEDURE public.dfl_script()
    OWNER TO rey;
