# Permission Set Comparator

A Salesforce Lightning Web Component (LWC) that lets you compare two or more Permission Sets side by side — built for admins and developers who are tired of clicking through Setup one permission set at a time.

---

## Why This Exists

Anyone who's managed Salesforce permissions knows the pain. You have two permission sets, a user is missing access to something, and you have no idea which one has it or what's different between them. The native Salesforce UI gives you no way to compare them side by side.

This tool fixes that.

---

## What It Does

Select any 2 or more permission sets from your org and instantly see a full side-by-side comparison across four areas:

**Object Permissions**
See Read, Create, Edit, Delete, View All, and Modify All access for every object — color coded so differences jump out immediately.

**Field Permissions**
Pick any object and see Read/Edit access for every single field on it. All fields shown — not just the ones with permissions already set.

**Apex Class Access**
See which Apex classes each permission set can execute. Searchable by class name.

**System Permissions**
All 200+ system permissions dynamically loaded from your org — including managed package permissions. Search by name or use the "Show Differences Only" toggle to instantly spot what's different between permission sets.

---

## Getting Started

### Prerequisites
- Salesforce CLI (`sf`) installed
- A Salesforce org (Developer Edition, Sandbox, or Scratch Org)
- VS Code with Salesforce Extension Pack (optional but recommended)

### Deploy via CLI

```bash
# Authenticate to your org
sf org login web --alias myOrg

# Deploy both Apex and LWC together
sf project deploy start --source-dir permissionSetComparator --target-org myOrg
```

### Deploy via VS Code

1. Open the `permissionSetComparator` folder in VS Code
2. Press `Ctrl+Shift+P` → **SFDX: Authorize an Org**
3. Right-click the top-level `permissionSetComparator` folder
4. Click **Deploy Source to Org**

---

## Adding It to a Page

1. Go to **Setup → App Builder**
2. Open any Home Page, App Page, or Tab
3. Find **permissionSetComparator** under Custom Components in the left panel
4. Drag it onto the page
5. Save and Activate

That's it. The component is live.

---

## How to Use It

**Step 1** — Type to search and select your permission sets. Selected ones appear as blue chips at the top.

**Step 2** *(optional)* — Filter by specific objects if you only want to compare a subset. Leave empty to compare everything.

**Step 3** — Hit **Compare Permission Sets**. Results load in a few seconds.

On the results page:
- Use the tabs to switch between Object, Field, Apex, and System permissions
- On the Field tab, search for any object by name to load its fields
- On the System Permissions tab, use the search bar or click **Show Differences Only** to highlight what's different
- Hit **Export CSV** to download the full comparison as a spreadsheet

---

## Project Structure

```
permissionSetComparator/
├── classes/
│   ├── PermissionSetComparatorController.cls
│   └── PermissionSetComparatorController.cls-meta.xml
└── lwc/
    └── permissionSetComparator/
        ├── permissionSetComparator.html
        ├── permissionSetComparator.js
        ├── permissionSetComparator.css
        └── permissionSetComparator.js-meta.xml
```

---

## Permissions Required

The user running the component needs:
- **View Setup and Configuration** — to query permission set metadata
- Access to the `PermissionSetComparatorController` Apex class

Grant both via a Permission Set assigned to your admins.

---

## Technical Notes

- **Objects** — loaded via `EntityDefinition` SOQL with OFFSET pagination, covering up to 2000 objects per org including all managed package objects
- **Fields** — loaded on demand per object via `FieldDefinition` SOQL with OFFSET pagination, covering up to 800 fields per object
- **System Permissions** — dynamically discovered via `Schema.describeSObjects` so every permission is captured including managed package ones — no hardcoded list
- **Export** — uses a data URI approach instead of `URL.createObjectURL` to work within Salesforce's Locker Service sandbox

---

## Known Limitations

- Permission Sets with more than 500 entries may be truncated in the selection list (increase the SOQL `LIMIT` in `getPermissionSets()` if needed)
- Field permissions show all fields on an object — for objects with 500+ fields this may take a few seconds to load
- The Apex Class tab only shows classes where at least one of the selected permission sets has access — classes with no access in any selected PS are hidden

---

## Contributing

Found a bug? Have an idea? Pull requests are welcome.

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/your-idea`)
3. Make your changes
4. Push and open a Pull Request

---

## License

MIT — use it, modify it, share it.

---

Built out of frustration at Salesforce's native permission comparison experience.
