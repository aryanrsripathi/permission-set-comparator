import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getPermissionSets from '@salesforce/apex/PermissionSetComparatorController.getPermissionSets';
import getOrgObjects     from '@salesforce/apex/PermissionSetComparatorController.getOrgObjects';
import comparePermSets   from '@salesforce/apex/PermissionSetComparatorController.comparePermSets';
import getFieldPerms     from '@salesforce/apex/PermissionSetComparatorController.getFieldPerms';

const EMPTY = [];

export default class PermissionSetComparator extends LightningElement {

    // ── Page ───────────────────────────────────────────────────────────────
    @track page = 'select';

    // ── Selection page ─────────────────────────────────────────────────────
    @track allPermSets    = [];
    @track psFilter       = '';
    @track selectedIds    = [];
    @track allOrgObjects  = [];
    @track objFilter      = '';
    @track selectedObjMap = {};
    @track isComparing    = false;
    @track compareError   = '';

    // ── Results ────────────────────────────────────────────────────────────
    @track result         = null;

    // Field tab
    @track fieldObjFilter  = '';
    @track activeObj       = '';
    @track activeObjLabel  = '';
    @track fieldFilter     = '';
    @track fieldRows       = [];
    @track loadingFields   = false;

    // Apex tab
    @track apexFilter      = '';

    // System Perms tab
    @track sysFilter       = '';
    @track showDiffOnly    = false;

    // ── Wire ───────────────────────────────────────────────────────────────
    @wire(getPermissionSets)
    wiredPS({ data, error }) {
        if (data) {
            this.allPermSets = data.map(ps => ({ ...ps, selected: false, cls: 'ps-item' }));
        } else if (error) {
            this.compareError = this._err(error);
        }
    }

    @wire(getOrgObjects)
    wiredObjs({ data, error }) {
        if (data)  { this.allOrgObjects = data; }
        else if (error) { this.compareError = this._err(error); }
    }

    // ── PS selection ───────────────────────────────────────────────────────
    handlePsFilter(e) {
        this.psFilter = e.target.value.toLowerCase();
        this._refreshList();
    }

    handlePsClick(e) {
        const id = e.currentTarget.dataset.id;
        const ps = this.allPermSets.find(p => p.id === id);
        if (!ps) return;
        ps.selected = !ps.selected;
        this.selectedIds = ps.selected
            ? [...this.selectedIds, id]
            : this.selectedIds.filter(x => x !== id);
        this._refreshList();
    }

    handleRemovePS(e) {
        e.stopPropagation();
        const id = e.currentTarget.dataset.id;
        const ps = this.allPermSets.find(p => p.id === id);
        if (ps) ps.selected = false;
        this.selectedIds = this.selectedIds.filter(x => x !== id);
        this._refreshList();
    }

    _refreshList() {
        const t = this.psFilter;
        this.allPermSets = this.allPermSets.map(ps => ({
            ...ps,
            cls:    ps.selected ? 'ps-item ps-item--on' : 'ps-item',
            hidden: t && !ps.label.toLowerCase().includes(t) && !ps.name.toLowerCase().includes(t)
        }));
    }

    // ── Object filter ──────────────────────────────────────────────────────
    handleObjFilter(e) { this.objFilter = e.target.value; }

    handlePickObj(e) {
        const api   = e.currentTarget.dataset.api;
        const label = e.currentTarget.dataset.label;
        this.selectedObjMap = { ...this.selectedObjMap, [api]: label };
        this.objFilter = '';
    }

    handleRemoveObj(e) {
        e.stopPropagation();
        const api = e.currentTarget.dataset.api;
        const m   = { ...this.selectedObjMap };
        delete m[api];
        this.selectedObjMap = m;
    }

    // ── Compare ────────────────────────────────────────────────────────────
    handleCompare() {
        this.compareError = '';
        this.isComparing  = true;
        const fo = Object.keys(this.selectedObjMap);
        comparePermSets({
            permSetIds:    this.selectedIds,
            filterObjects: fo.length ? fo : null
        })
        .then(r => {
            this.result         = r;
            this.isComparing    = false;
            this.page           = 'results';
            this.activeObj      = '';
            this.activeObjLabel = '';
            this.fieldRows      = [];
            this.fieldFilter    = '';
            this.fieldObjFilter = '';
            this.apexFilter     = '';
            this.sysFilter      = '';
            this.showDiffOnly   = false;
        })
        .catch(e => {
            this.isComparing  = false;
            this.compareError = this._err(e);
        });
    }

    handleBack() { this.page = 'select'; }

    // ── Field tab ──────────────────────────────────────────────────────────
    handleFieldObjFilter(e) { this.fieldObjFilter = e.target.value; }

    handlePickFieldObj(e) {
        this.activeObj      = e.currentTarget.dataset.value;
        this.activeObjLabel = e.currentTarget.dataset.label;
        this.fieldObjFilter = '';
        this.fieldFilter    = '';
        this.fieldRows      = [];
        this.loadingFields  = true;
        getFieldPerms({ permSetIds: this.selectedIds, objectApiName: this.activeObj })
        .then(rows => { this.fieldRows = rows; this.loadingFields = false; })
        .catch(err => { this.loadingFields = false; this._toast('Error loading fields', this._err(err), 'error'); });
    }

    handleClearFieldObj() {
        this.activeObj      = '';
        this.activeObjLabel = '';
        this.fieldRows      = [];
        this.fieldFilter    = '';
        this.fieldObjFilter = '';
    }

    handleFieldFilter(e) { this.fieldFilter = e.target.value.toLowerCase(); }

    // ── Apex tab ───────────────────────────────────────────────────────────
    handleApexFilter(e) { this.apexFilter = e.target.value.toLowerCase(); }

    // ── System Perms tab ───────────────────────────────────────────────────
    handleSysFilter(e)   { this.sysFilter = e.target.value.toLowerCase(); }
    handleDiffToggle()   { this.showDiffOnly = !this.showDiffOnly; }

    // ── Export CSV ─────────────────────────────────────────────────────────
    handleExport() {
        try {
            const r      = this.result;
            const labels = r.permSetLabels;
            let csv      = '\uFEFF';

            // Object Permissions
            csv += 'OBJECT PERMISSIONS\n';
            csv += 'Object,' + labels.map(l =>
                l + ' Read,' + l + ' Create,' + l + ' Edit,' + l + ' Delete,' + l + ' ViewAll,' + l + ' ModifyAll'
            ).join(',') + '\n';
            (r.objectPerms || []).forEach(row => {
                csv += '"' + row.objectLabel + '",' +
                    row.cells.map(c =>
                        [c.canRead, c.canCreate, c.canEdit, c.canDelete, c.canViewAll, c.canModifyAll]
                        .map(v => v ? 'Yes' : 'No').join(',')
                    ).join(',') + '\n';
            });

            // Field Permissions (if loaded)
            if (this.fieldRows.length && this.activeObj) {
                csv += '\nFIELD PERMISSIONS - ' + this.activeObjLabel + '\n';
                csv += 'Field,' + labels.map(l => l + ' Read,' + l + ' Edit').join(',') + '\n';
                this.fieldRows.forEach(row => {
                    csv += '"' + row.fieldLabel + '",' +
                        row.cells.map(c => [c.canRead, c.canEdit].map(v => v ? 'Yes' : 'No').join(',')).join(',') + '\n';
                });
            }

            // Apex Class Access
            csv += '\nAPEX CLASS ACCESS\n';
            csv += 'Class,' + labels.join(',') + '\n';
            (r.apexAccess || []).forEach(row => {
                csv += '"' + row.className + '",' + row.access.map(c => c.enabled ? 'Yes' : 'No').join(',') + '\n';
            });

            // System Permissions — export ALL, not just filtered view
            csv += '\nSYSTEM PERMISSIONS\n';
            csv += 'Permission,' + labels.join(',') + '\n';
            (r.sysPerms || []).forEach(row => {
                csv += '"' + row.permLabel + '",' + row.values.map(c => c.enabled ? 'Yes' : 'No').join(',') + '\n';
            });

            const encodedCsv = encodeURIComponent(csv);
            const dataUri    = 'data:text/csv;charset=utf-8,' + encodedCsv;
            const link       = this.template.querySelector('a.download-link');
            if (link) {
                link.setAttribute('href', dataUri);
                link.setAttribute('download', 'PermSetComparison.csv');
                link.click();
                this._toast('Exported', 'CSV downloaded successfully.', 'success');
            }
        } catch (e) {
            this._toast('Export failed', e.message, 'error');
        }
    }

    // ── Getters ────────────────────────────────────────────────────────────
    get onSelectPage()   { return this.page === 'select'; }
    get onResultsPage()  { return this.page === 'results'; }

    get visiblePermSets()  { return this.allPermSets.filter(ps => !ps.hidden); }
    get selectedPermSets() { return this.allPermSets.filter(ps => ps.selected); }
    get selectedCount()    { return this.selectedIds.length; }
    get hasSelected()      { return this.selectedIds.length > 0; }
    get cannotCompare()    { return this.selectedIds.length < 2 || this.isComparing; }
    get noPsResults()      { return this.visiblePermSets.length === 0; }

    // Object filter
    get objDropdownItems() {
        if (!this.objFilter) return EMPTY;
        const t = this.objFilter.toLowerCase();
        return this.allOrgObjects
            .filter(o => o.label.toLowerCase().includes(t) || o.apiName.toLowerCase().includes(t))
            .slice(0, 25);
    }
    get showObjDropdown()  { return this.objFilter.length > 0; }
    get noObjResults()     { return this.showObjDropdown && this.objDropdownItems.length === 0; }
    get selectedObjList()  {
        return Object.keys(this.selectedObjMap).map(api => ({ apiName: api, label: this.selectedObjMap[api] }));
    }
    get hasSelectedObjs()  { return this.selectedObjList.length > 0; }

    // Legend + sub-headers
    get psLegend() {
        if (!this.result) return EMPTY;
        return this.result.permSetIds.map((id, i) => ({ id, label: this.result.permSetLabels[i] }));
    }
    get objSubHeaders() {
        if (!this.result) return EMPTY;
        const cols = ['R','C','E','D','VA','MA'];
        return this.result.permSetIds.flatMap((id, i) =>
            cols.map((col, j) => ({ id: id + '-' + col + '-' + i + '-' + j, label: col }))
        );
    }
    get fieldSubHeaders() {
        if (!this.result) return EMPTY;
        return this.result.permSetIds.flatMap((id, i) =>
            ['Read','Edit'].map((col, j) => ({ id: id + '-' + col + '-' + i + '-' + j, label: col }))
        );
    }

    // Object Perms — safe null guard
    get objectPermRows() {
        return (this.result && this.result.objectPerms) ? this.result.objectPerms : EMPTY;
    }
    get noObjectRows() { return this.objectPermRows.length === 0; }

    // Field tab
    get fieldObjItems() {
        if (!this.fieldObjFilter) return EMPTY;
        const t = this.fieldObjFilter.toLowerCase();
        return this.allOrgObjects
            .filter(o => o.label.toLowerCase().includes(t) || o.apiName.toLowerCase().includes(t))
            .slice(0, 25);
    }
    get showFieldObjDropdown() { return this.fieldObjFilter.length > 0; }
    get noFieldObjItems()      { return this.showFieldObjDropdown && this.fieldObjItems.length === 0; }
    get filteredFieldRows() {
        const rows = this.fieldRows || EMPTY;
        if (!this.fieldFilter) return rows;
        const t = this.fieldFilter;
        return rows.filter(r => r.fieldLabel.toLowerCase().includes(t) || r.fieldApiName.toLowerCase().includes(t));
    }
    get showFieldTable()   { return !!this.activeObj && !this.loadingFields; }
    get showFieldEmpty()   { return !this.activeObj; }
    get noFieldRows()      { return this.showFieldTable && this.filteredFieldRows.length === 0; }

    // Apex tab
    get filteredApexRows() {
        const rows = (this.result && this.result.apexAccess) ? this.result.apexAccess : EMPTY;
        if (!this.apexFilter) return rows;
        const t = this.apexFilter;
        return rows.filter(r => r.className.toLowerCase().includes(t));
    }
    get noApexRows() {
        return !this.result || !this.result.apexAccess || this.result.apexAccess.length === 0;
    }

    // System Perms tab — search + diff toggle
    get filteredSysRows() {
        const rows = (this.result && this.result.sysPerms) ? this.result.sysPerms : EMPTY;
        let filtered = rows;

        // Text filter
        if (this.sysFilter) {
            const t = this.sysFilter;
            filtered = filtered.filter(r =>
                r.permLabel.toLowerCase().includes(t) ||
                r.permApiName.toLowerCase().includes(t)
            );
        }

        // Diff only — show rows where values differ across perm sets
        if (this.showDiffOnly) {
            filtered = filtered.filter(r => {
                const vals = r.values.map(c => c.enabled);
                return !vals.every(v => v === vals[0]);
            });
        }

        return filtered;
    }
    get noSysRows()        { return this.filteredSysRows.length === 0; }
    get diffBtnLabel()     { return this.showDiffOnly ? 'Show All' : 'Show Differences Only'; }
    get diffBtnVariant()   { return this.showDiffOnly ? 'brand' : 'neutral'; }
    get sysRowCount()      {
        const total    = (this.result && this.result.sysPerms) ? this.result.sysPerms.length : 0;
        const filtered = this.filteredSysRows.length;
        return 'Showing ' + filtered + ' of ' + total + ' permissions';
    }

    // ── Utilities ──────────────────────────────────────────────────────────
    _err(e) {
        if (typeof e === 'string') return e;
        if (e && e.body && e.body.message) return e.body.message;
        if (e && e.message) return e.message;
        return JSON.stringify(e);
    }
    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
