"""Offline MLX reference for parity tests of the Swift GLiNER2.5 port."""
import argparse
import json
from pathlib import Path
import mlx.core as mx
from transformers import AutoTokenizer
from mlx_vlm.models.gliner2_5.config import ModelConfig
from mlx_vlm.models.gliner2_5.gliner2_5 import Model, _schema_tokens

parser = argparse.ArgumentParser()
parser.add_argument('--model', type=Path, default=Path('models/GLiNER2.5-Base'))
parser.add_argument('--output', type=Path, default=Path('/tmp/TicketApp-GLiNER-reference'))
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
config = ModelConfig.from_dict(json.loads((args.model / 'config.json').read_text()))
model = Model(config)
model.load_weights(list(model.sanitize(mx.load(str(args.model / 'model.safetensors'))).items()), strict=True)
model.eval()
mx.eval(model.parameters())
processor = AutoTokenizer.from_pretrained(str(args.model), local_files_only=True)
text = 'SUBTOTAL 44.17\nHST 5.74\nTOTAL 49.91'
labels = {'subtotal': 'printed receipt subtotal amount', 'tax': 'printed tax amount such as HST or GST', 'total': 'printed final receipt total amount'}
prepared = model._prepare(processor, text, _schema_tokens('entities', list(labels), '[E]', descriptions=labels))
encoded = model.encode(prepared.input_ids)
t = encoded[:, prepared.word_positions]
q = encoded[:, prepared.marker_positions[1:]]
pool, logits, nulls = model.extract(t, mx.ones(t.shape[:2], dtype=mx.bool_), q, mx.ones(q.shape[:2], dtype=mx.bool_))
mx.save_safetensors(str(args.output / 'reference.safetensors'), {'ids': prepared.input_ids, 'encoded': encoded, 'pairs': pool.indices, 'logits': logits, 'nulls': nulls})
result = model.extract_entities(processor, text, labels, include_confidence=True, include_spans=True)
(args.output / 'reference.json').write_text(json.dumps({'text': text, 'labels': labels, 'words': prepared.word_positions, 'markers': prepared.marker_positions, 'offsets': prepared.offsets, 'result': result}, indent=2))
print(json.dumps(result), flush=True)
