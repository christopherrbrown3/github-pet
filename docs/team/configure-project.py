#!/usr/bin/env python3
"""Idempotently populate the GitHub Pet Project via the authenticated local gh CLI."""
import json
from pathlib import Path
import subprocess
OWNER = 'christopherrbrown3'
REPO = OWNER + '/github-pet'
def gh(*args):
    result = subprocess.run(['gh', *args], text=True, capture_output=True, check=True)
    return json.loads(result.stdout)
def graphql(query, **variables):
    payload = json.dumps({'query': query, 'variables': variables})
    result = subprocess.run(['gh', 'api', 'graphql', '--input', '-'], input=payload, text=True, capture_output=True, check=True)
    data = json.loads(result.stdout)
    if data.get('errors'):
        raise RuntimeError(data['errors'])
    return data['data']
projects = gh('project', 'list', '--owner', OWNER, '--limit', '100', '--format', 'json')['projects']
project = next((p for p in projects if p['title'] == 'GitHub Pet — Development'), None)
if project is None:
    project = gh('project', 'create', '--owner', OWNER, '--title', 'GitHub Pet — Development', '--format', 'json')
number, project_id = str(project['number']), project['id']
fields = gh('project', 'field-list', number, '--owner', OWNER, '--limit', '100', '--format', 'json')['fields']
status = next(f for f in fields if f['name'] == 'Status')
statuses = ['Inbox', 'Backlog', 'Ready', 'In Progress', 'In Review', 'In QA', 'Done', 'Blocked']
existing = {o['name']: o for o in status['options']}
if [o['name'] for o in status['options']] != statuses:
    # Preserve custom options on an existing project; default options map to the new workflow.
    extra = [n for n in existing if n not in statuses and n not in ['Todo', 'In Progress', 'Done']]
    opts = []
    for name in statuses + extra:
        option = {'name': name, 'color': 'RED' if name == 'Blocked' else 'GREEN' if name == 'Done' else 'GRAY', 'description': name}
        old = existing.get(name) or (existing.get('Todo') if name == 'Inbox' else None)
        if old: option['id'] = old['id']
        opts.append(option)
    graphql('mutation($id:ID!,$opts:[ProjectV2SingleSelectFieldOptionInput!]) { updateProjectV2Field(input:{fieldId:$id,singleSelectOptions:$opts}) { projectV2Field { ... on ProjectV2SingleSelectField { id } } } }', id=status['id'], opts=opts)
for name, options in [('Owner Agent', ['product-manager','developer','graphic-designer','qa-engineer']), ('Priority',['P0','P1','P2']), ('Type',['epic','feature','task'])]:
    if not any(f['name'] == name for f in fields):
        gh('project', 'field-create', number, '--owner', OWNER, '--name', name, '--data-type', 'SINGLE_SELECT', '--single-select-options', ','.join(options), '--format', 'json')
# Milestone is GitHub's built-in issue milestone field, populated on every issue below.
fields = gh('project', 'field-list', number, '--owner', OWNER, '--limit', '100', '--format', 'json')['fields']
by_name = {f['name']: f for f in fields}
rows = json.loads((Path(__file__).parent / 'backlog.json').read_text())
prior_items = gh('project','item-list',number,'--owner',OWNER,'--limit','1000','--format','json')['items']
prior_status = {i.get('content', {}).get('url'): i.get('status') for i in prior_items}
for row in rows:
    item = gh('project', 'item-add', number, '--owner', OWNER, '--url', row['url'], '--format', 'json')
    state = prior_status.get(row['url']) or ('In Progress' if row['number'] in [1,2,3,4,5] else 'Backlog')
    for name, value in [('Status',state),('Owner Agent',row['owner']),('Priority',row['priority']),('Type',row['kind'])]:
        field = by_name[name]
        option = next(o for o in field['options'] if o['name'] == value)
        gh('project','item-edit','--id',item['id'],'--project-id',project_id,'--field-id',field['id'],'--single-select-option-id',option['id'],'--format','json')
    print(row['number'], state, flush=True)
views = graphql('query($id:ID!) { node(id:$id) { ... on ProjectV2 { views(first:100) { nodes { id name layout number } } } } }', id=project_id)['node']['views']['nodes']
view = next((v for v in views if v['name'] == 'Development Board'), None)
visible = [by_name[n]['id'] for n in ['Title','Owner Agent','Priority','Type','Milestone'] if n in by_name]
if view:
    graphql('mutation($id:ID!,$fields:[ID!]) { updateProjectV2View(input:{viewId:$id,name:"Development Board",layout:BOARD_LAYOUT,configuration:{visibleFieldIds:$fields}}) { projectV2View { id } } }', id=view['id'], fields=visible)
elif views:
    view = views[0]
    graphql('mutation($id:ID!,$fields:[ID!]) { updateProjectV2View(input:{viewId:$id,name:"Development Board",layout:BOARD_LAYOUT,configuration:{visibleFieldIds:$fields}}) { projectV2View { id } } }', id=view['id'], fields=visible)
else:
    view = graphql('mutation($id:ID!,$fields:[ID!]) { createProjectV2View(input:{projectId:$id,name:"Development Board",layout:BOARD_LAYOUT,configuration:{visibleFieldIds:$fields}}) { projectV2View { id number } } }', id=project_id, fields=visible)['createProjectV2View']['projectV2View']
subprocess.run(['gh','project','link',number,'--owner',OWNER,'--repo',REPO],check=True)
print(json.dumps({'project':project,'view':view},indent=2))
