Data Ingestion

This repository contains automated data ingestion scripts for HealthSnap, an operating platform dedicated to Chronic Case Management (CCM) and Remote Patient Monitoring (RPM). HealthSnap collaborates with Medicare seniors sourced from various healthcare facilities nationwide, ranging from large nonprofit systems like Prisma Health to independent practices such as Cobb Nephrology.

Background

Once healthcare facilities onboard patients onto HealthSnap's platform, the patient information is submitted to HealthSnap's Electronic Health Records (EHR) data team for processing. To ensure eligibility for Chronic Case Management (CCM) and Remote Patient Monitoring (RPM) services, several criteria need to be evaluated, including:

Insurance Eligibility: Is the patient covered under primary or secondary insurance for CCM/RPM services?
Device Compatibility: Based on the patient's ICD codes, determining the most suitable RPM devices like blood pressure monitors, blood glucometers, and pulse oximeters.
Initially, this eligibility screening was done manually using Excel, employing pivot tables and filtering. However, manual processing led to errors and was challenging to repeat consistently.

Automation Solution

To streamline this critical eligibility screening process, this repository houses a collection of automated SQL scripts tailored to the specific requirements of each healthcare facility. These scripts are designed to run on Postgres/pgAdmin4, ensuring efficient and accurate data processing.

Technologies Used

Database: Postgres/pgAdmin4
Version Control: Sourcetree/BitBucket
API Logic: Postman

Folder Structure
/scripts: Contains automated SQL scripts for eligibility screening, each customized for individual healthcare facilities.
/documentation: Additional documentation files, if any.

How to Use

Clone the Repository:

bash
Copy code
git clone https://github.com/yourusername/healthsnap-data-ingestion.git
cd healthsnap-data-ingestion
Run the Scripts:

Open the relevant script in Postgres/pgAdmin4.
Execute the script to process the patient data and screen for eligibility.

Contribution and Issues
If you find any issues or want to contribute to enhancing these scripts, please follow these steps:

Fork the repository.
Create a new branch: git checkout -b feature/your-feature-name
Make your changes and commit them: git commit -m 'Add your feature'
Push to the branch: git push origin feature/your-feature-name
Submit a pull request outlining the changes made.
