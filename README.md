In order to launch this h360tk_grafana_core:

```
git clone git@github.com:simpledotorg/h360tk_grafana_core.git
cd h360tk_grafana_core
docker compose up -d
```

Then just go to this url:

http://localhost:3000/d/heart360_drilldown/hearts360-hypertension-dashboard

to upload file:

http://localhost:8080/

---

# HEARTS360 Toolkit

HEARTS360 Toolkit is a Grafana-based system designed to help District Health Offices monitor hypertension care across facilities. The system processes patient line list data and generates visual dashboards.

## What is HEARTS360 Toolkit

HEARTS360 Toolkit is a Grafana-based system designed to help District Health Offices monitor hypertension care across facilities. The system processes patient line list data and generates visual dashboards that show:

- **Facility-level dashboards:** Each facility can see their own patient data and performance metrics
- **District-level dashboards:** District health office can see aggregated data across all facilities
- **Overdue line lists:** Lists of patients who need follow-up care

## Key Use Cases

HEARTS360 Toolkit supports three main use cases:

**Routine Data Monitoring:** Facility staff export monthly patient line lists from their system and upload CSV or Excel files to HEARTS360 Toolkit. The system automatically processes the data and updates dashboards, providing real-time visibility into care delivery, easy identification of patients needing follow-up, and trend analysis over time.

**Dashboard Validation:** Staff upload CSV or Excel line list files to HEARTS360 Toolkit and compare the charts with their EHR system dashboards to validate data accuracy, identify data entry errors, and ensure reporting consistency.

**District-Level Oversight:** Each facility uploads their data, and district team views the district-level dashboard to monitor hypertension care across all facilities. This enables district-wide visibility without compromising patient privacy, supports data-driven decision making, and helps allocate resources based on need.

### Direct EHR aggregate ingestion (MVP)

The central importer can read aggregate indicator JSON from an EHR. The EHR does not send a patient line list.

Start with `docs/ehr-aggregate-indicator-requirements.md`. That file is the parent list. It links the vendor text, the JSON shape, the checklist, the code, the migration, the examples, and the branch.

The spike report is `docs/central-aggregate-ingest-investigation.md`. It combines the investigation, the examples, and the recommended path.

---

## Technical Documentation

### System Overview

HEARTS360 Toolkit is built using:
- **Grafana:** Dashboard visualization platform
- **PostgreSQL:** Database for storing patient and encounter data
- **FileBrowser Quantum:** Web-based file upload interface
- **Python:** Data ingestion scripts
- **Docker:** Containerization for easy deployment

### Installation Instructions

#### Prerequisites

- Docker Desktop installed and running
- Git installed
- At least 4GB RAM available
- Internet connection

#### Step 1: Install Docker Desktop

**For macOS:**
brew install --cask dockerOpen Docker Desktop application and wait for it to start.

**For other operating systems:** Download Docker Desktop from [docker.com](https://www.docker.com/products/docker-desktop)

#### Step 2: Launch HEARTS360 Toolkit
```
git clone git@github.com:simpledotorg/h360tk_grafana_core.git
cd h360tk_grafana_core
docker compose up -d
```
`docker compose up -d` command will:
- Download required Docker images (first time only)
- Start PostgreSQL database
- Start Grafana dashboard server
- Start FileBrowser for file uploads
- Start file processing service

Wait 30-60 seconds for all services to initialize.

#### Step 4: Verify Installation

1. **Check Grafana Dashboard:**
   - Open browser: `http://localhost:3000`
   - Login with: `admin` / `admin`
   - You should see the "Hypertension Program" dashboard

2. **Check File Upload:**
   - Open browser: `http://localhost:8080`
   - Login with: `admin` / `admin`
   - You should see the file upload interface

3. **Check Database:**
   - PostgreSQL is running on port 5432
   - Database name: `metrics_db`
   - Username: `grafana_user`
   - Password: `your_db_password`


#### Step 5: Test with Sample Data

1. Upload a test CSV or Excel file through FileBrowser (`http://localhost:8080`)
2. The file should be automatically processed.
3. The uploaded data is saved immediately in the database, but the dashboard graphs will **not** update straight away because they use precomputed data that needs to be refreshed first.
4. Manually trigger a refresh from the **Data Refresh Dashboard** page (`http://localhost:3000/d/heart360-data-refresh`) to see the data immediately (see [Data Refresh Dashboard — Refreshing Dashboard Data](<docs/Grafana Data Refresh Dashboard – Visual Documentation.md>)).


#### Step 6: Set Up User Access

- **[User Access Setup Guide](docs/user-access-setup-guide.md)** — How to add users and control which facility's data they can see.

### Updating the System

To get the latest changes from the repository:
```
git pull
docker compose down
docker compose up -d
```
### Database Considerations

#### Current Setup: PostgreSQL

The system currently uses **PostgreSQL** as the database. This is the recommended setup because:
- The system is already configured and tested with PostgreSQL
- All SQL queries and functions are written for PostgreSQL
- Changing to MySQL would require significant code modifications

#### If You Need MySQL

You have two options:

**Option 1: Use PostgreSQL (Recommended)**
- Install PostgreSQL alongside MySQL
- They can coexist on the same machine
- Minimal changes needed to the system
- Easier to maintain and update

**Option 2: Adapt to MySQL**
- Requires modifying SQL queries (PostgreSQL-specific syntax)
- Need to rewrite database functions
- May require changes to Python ingestion scripts

**Recommendation:** Use PostgreSQL for HEARTS360 Toolkit, even if other systems use MySQL. This keeps the system simple and maintainable.

### System Architecture

#### Components

1. **Grafana Container**
   - Port: 3000
   - Purpose: Dashboard visualization
   - Configuration: `grafana_provisioning/`

2. **PostgreSQL Container**
   - Port: 5432
   - Purpose: Data storage
   - Initialization scripts: `pg_init_scripts/`

3. **FileBrowser Container**
   - Port: 8080
   - Purpose: File upload interface
   - Upload directory: `data/upload/`

4. **File Processor Container**
   - Purpose: Watches for new files and processes them
   - Scripts: `inotify_scripts/`

#### Data Flow

The system processes uploaded files through the following workflow:

1. **File Upload:** User uploads a CSV or Excel (.xlsx) file via the FileBrowser web interface.

   **Note:** We recommend using **CSV** files for data import, as they provide faster ingestion. **Excel (.xlsx)** files are also supported but may take longer to process.
   
2. **File Storage:** File is saved to `data/upload/` directory
3. **File Detection:** File processor detects new file (using inotify)
4. **Data Processing:** Python script (`ingest_file_h360tk.py`) processes the file
5. **Database Insertion:** Data is inserted into PostgreSQL raw tables (`heart360tk_schema`)
6. **Data Refresh Needed:** Uploaded data is saved in the database, but the dashboard graphs do **not** update until the dashboard data is refreshed (see [Data Refresh Dashboard — Refreshing Dashboard Data](<docs/Grafana Data Refresh Dashboard – Visual Documentation.md>))
7. **Dashboard Display:** After a refresh, Grafana shows the updated data on the dashboards

### Data Refresh Dashboard — Refreshing Dashboard Data

When a sheet is uploaded, the data is saved in the database immediately, but it will **not** show up in the dashboard graphs straight away. The dashboards use precomputed data that needs to be refreshed first.

A refresh happens in two ways:

- **Automatically:** the data refreshes on its own once every hour.
- **Manually (admin only):** an admin can refresh it right away from the **Data Refresh Dashboard** instead of waiting for the hourly update.

#### Who can refresh

Only admins can refresh the dashboard data. Non-admin users will see an "Access Denied" message on this dashboard and cannot run a refresh.

#### How to refresh after uploading a sheet

1. Upload the sheet via FileBrowser (`http://localhost:8080`) and wait for it to be processed. The data is now in the database but not yet visible in the graphs.
2. Open the **Data Refresh Dashboard**: `http://localhost:3000/d/heart360-data-refresh`
3. Click the **⟳ Refresh Dashboard** button and confirm. The refresh runs in the background and may take a few minutes.
4. Wait for the status on the dashboard to finish (it moves through **Queued → Refreshing… → All Good**).
5. Once it shows the refresh is complete, open any dashboard (Hypertension, Diabetes, Overdue, etc.) and the newly uploaded data will now be visible.

