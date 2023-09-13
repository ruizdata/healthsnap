-- PROCEDURE: public.cherokee_script()

-- DROP PROCEDURE IF EXISTS public.cherokee_script();

CREATE OR REPLACE PROCEDURE public.cherokee_script(
	)
LANGUAGE 'sql'
AS $BODY$
/* Cherokee Script

Set-Up

A.	Establish a connection to the VPN using L2TP and provide your username and password when prompted.
B.	In pgAdmin, navigate to the following location: Servers > HealthSnap Onboarding > Databases > healthsnap_onboarding > Schemas > public > Tables.
C.	Import the required files as CSV. For each file, create a table and name it accordingly. Add columns with data types set to "character varying". Ensure that the column titles exactly match the headers in the CSV files. Additionally, enable the "Header" option under the import settings.

Required Files: cherokee_import,
				cherokee_exclusions, 
				cherokee_providers 
*/

-- Please execute this code block manually to modify the structure of the table.

DO $$ 
DECLARE
    column_changes text[][];
    i int;
BEGIN
    column_changes := ARRAY[
        ['medical_record_number__c', 'mrn'],
        ['first_name__c', 'first_name'],
        ['last_name__c', 'last_name'],
		['insurance_type__c', 'primary_insurance'],
        ['secondary_insurance_type__c', 'secondary_insurance'],
        ['home_phone__c', 'home_phone'],
		['mobile_phone__c', 'cell_phone'],
        ['email__c', 'email'],
        ['street_address__c', 'address_line1'],
        ['streetadress2', 'address_line2'],
        ['city__c', 'city'],
        ['state__c', 'state'],
        ['postal_Code__c', 'zip'],
		['provider_first_name__c', 'provider_first_name'],
		['provider_last_name__c', 'provider_last_name']
    ];

    FOR i IN 1..array_length(column_changes, 1)
    LOOP
        IF EXISTS (SELECT * FROM information_schema.columns WHERE table_name = 'cherokee_import' AND column_name = column_changes[i][1]) 
           AND NOT EXISTS (SELECT * FROM information_schema.columns WHERE table_name = 'cherokee_import' AND column_name = column_changes[i][2]) THEN
            EXECUTE format('ALTER TABLE cherokee_import RENAME COLUMN %I TO %I', column_changes[i][1], column_changes[i][2]);
        END IF;
    END LOOP;
END $$;


ALTER TABLE IF EXISTS cherokee_import
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

-- 1.	Remove MRNs already in the Exclusions list.

UPDATE cherokee_import
SET delete = TRUE
WHERE "mrn" IN (
    SELECT "MRN" FROM cherokee_exclusions
);

-- 2.	Remove duplicate MRNs.

UPDATE cherokee_import
SET delete = TRUE
WHERE ctid NOT IN (
   SELECT min(ctid) 
   FROM cherokee_import 
   GROUP BY "mrn"
);

-- 3.	Remove blank MRNs.

UPDATE cherokee_import
SET delete = TRUE
WHERE "mrn" IS NULL OR TRIM("mrn") = '';

-- 4.	Remove patients whose primary insurance is not Medicare, Medicare Part A and B, or Medicare Part B.

UPDATE cherokee_import
SET delete = TRUE
WHERE "primary_insurance" NOT LIKE 'MEDICARE A AND B';

-- 5.	Remove patients whose secondary insurance contain Tricare, ChampVA, BCBS of South Carolina, or blank.

UPDATE cherokee_import
SET delete = TRUE
WHERE "secondary_insurance" LIKE '%TRICARE%'
   OR "secondary_insurance" LIKE '%ChampVA%'
   OR "secondary_insurance" LIKE '%MEDICAID%'
   OR "secondary_insurance" LIKE '%BLUE CROSS BLUE SHIELD SC%'
   OR "secondary_insurance" IS NULL
   OR "secondary_insurance" = '';

-- 6.	Make patients name proper case.

UPDATE cherokee_import
SET "first_name" = UPPER(LEFT("first_name", 1)) || LOWER(SUBSTRING("first_name", 2)),
    "last_name" = UPPER(LEFT("last_name", 1)) || LOWER(SUBSTRING("last_name", 2));

-- 7.	Remove dashes from phone numbers.

UPDATE cherokee_import
SET "home_phone" = REPLACE(REPLACE(REPLACE(REPLACE("home_phone", '(', ''), ')', ''), '-', ''), ' ', '');

-- 8.   If the home phone is misssing, use the mobile phone.

UPDATE cherokee_import
SET "home_phone" = CASE
    WHEN "cell_phone" IS NOT NULL AND "cell_phone" <> '' THEN "cell_phone"
    ELSE "home_phone"
    END;

-- 9.   Fill blank patient emails using the format newberry+<MRN>@healthsnap.io.

UPDATE cherokee_import
SET "email" = CONCAT('cherokeeregional+', "mrn", '@healthsnap.io')
WHERE "email" IS NULL OR "email" = '';

-- 11. Add provider emails and signatures.

UPDATE cherokee_import
SET provider_full_name = provider_first_name || ' ' || provider_last_name;

UPDATE cherokee_import
SET provider_email = cherokee_providers."Email"
FROM cherokee_providers
WHERE cherokee_import.provider_full_name = cherokee_providers."Provider Name";

-- 12. Set enrollment date to today.

UPDATE cherokee_import
SET enrollment_date = CURRENT_DATE;

-- 14. Select edited list

SELECT *
FROM cherokee_import
WHERE delete = FALSE;

$BODY$;

ALTER PROCEDURE public.cherokee_script()
    OWNER TO rey;
