"""ModelCatalog summed-bucket pricing, from an unchanged Swift catalog export."""
import json,re
from datetime import datetime,timezone,timedelta
from decimal import Decimal
from functools import lru_cache
from pathlib import Path

CONTRACT=Path(__file__).parent/'assets/upstream-pricing-contract.json'


@lru_cache(maxsize=1)
def catalog():
    try:return json.loads(CONTRACT.read_text(encoding='utf-8'))
    except (OSError,ValueError):return dict(models={},vendorServices={})


def listing(model,region='international',contract=None):
    contract=catalog() if contract is None else contract
    name,separator,route=str(model).partition('#')
    name=name.split('-model:',1)[-1].lower()
    if name.endswith('[1m]'):name=name[:-4]
    name=re.sub(r'-[0-9]{8}$|-[0-9]{4}-[0-9]{2}-[0-9]{2}$','',name)
    item=contract['models'].get(name)
    if not item or separator and contract['vendorServices'].get(route)!=item['vendor']:return None
    price=item['prices'].get(region)
    if price is None and item['global']:price=item['prices'].get('international')
    return (item,price) if price else None


def summed_cost(model,counts,region='international',at=None,contract=None):
    found=listing(model,region,contract)
    if found is None:return None
    item,price=found;rates=price['rates']
    # Ledger input includes cache writes; output includes reasoning. The source
    # TokenKinds representation separates them; do not price either subset twice.
    inp=counts.get('input',0);write=counts.get('cache_write',0)
    values=dict(input=max(0,inp-write),cache_write=write,
                cache=counts.get('cache',0),output=counts.get('output',0))
    amount=sum(Decimal(values[key])*Decimal(rates[key]) for key in values)/Decimal(1000000)
    if item['peak_hours'] and at is not None:
        date=datetime.fromtimestamp(at,timezone(timedelta(hours=8)))
        if date.weekday()<5 and (9<=date.hour<12 or 14<=date.hour<18):amount*=2
    return dict(currency=price['currency'],amount=amount)
